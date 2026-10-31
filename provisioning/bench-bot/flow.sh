#!/usr/bin/env bash
# flow.sh
# デプロイ → SQL統計のリセット → ベンチ → alp とスロークエリの確認 → Discord 通知 を続けて行う
# 実行中のベンチがあると完了まで待つので、実行ツールのタイムアウトは15分以上にする
#
# 使い方:
#   bash provisioning/bench-bot/flow.sh                # デプロイから通知まで
#   bash provisioning/bench-bot/flow.sh --skip-deploy  # 今サーバーにあるコードでベンチから通知まで
#   bash provisioning/bench-bot/flow.sh --force        # origin/main を取り込んでいなくてもデプロイする
#
# 実行中のベンチがあると完了後に投入するので、そのベンチの SQL も統計に混ざる。
# レポートは ~/.cache/isucon2026/reports/ に保存する。
#
# 終了コード: 0 = 成功、1 = デプロイの失敗または走行が FAIL、2 = それ以外の失敗

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISIONING_DIR="$(dirname "$SCRIPT_DIR")"
ASIA1="isucon@57.181.195.208"
DB_HOST="isucon@54.65.131.246"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)
REPORT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/isucon2026/reports"

SKIP_DEPLOY=0
FORCE=0
for ARG in "$@"; do
  case "$ARG" in
    --skip-deploy) SKIP_DEPLOY=1 ;;
    --force) FORCE=1 ;;
    *) echo "Usage: $0 [--skip-deploy] [--force]" >&2; exit 2 ;;
  esac
done

# Webhook URL は asia1 にしか置かないので、asia1 の bot.py を使って送る。
notify() {
  local content="$1" report="$2"
  { printf '%s\n---REPORT---\n' "$content"; cat "$report"; } | ssh "${SSH_OPTS[@]}" "$ASIA1" '
    cd /home/isucon/bench-bot
    DISCORD_WEBHOOK_URL="$(sed -n "s/^DISCORD_WEBHOOK_URL=//p" env)" python3 -B -c "
import sys
import bot
content, _, report = sys.stdin.buffer.read().decode(errors=\"replace\").partition(\"\n---REPORT---\n\")
bot.send_discord(content, (\"flow-report.md\", report))
"
  '
}

# measure.sh の外から走らせるときは、PR の計測を待たせる。失敗しても手元のベンチは止めない。
HOLDING=0
if [ -z "${MEASURE_RUN:-}" ]; then
  if bash "$SCRIPT_DIR/measure.sh" hold; then
    HOLDING=1
  else
    echo "WARN: PR の計測を止められませんでした。そのまま続けます" >&2
  fi
fi
cleanup() {
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
  [ "$HOLDING" -eq 1 ] && bash "$SCRIPT_DIR/measure.sh" release-hold
}
trap cleanup EXIT

# worktree の .git はファイルなので、deploy.sh の rsync がサーバーの .git で失敗して途中で止まる。
check_deployable() {
  local root
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" || return 1
  if [ -f "$root/.git" ]; then
    echo "ERROR: git worktree からは deploy.sh を実行できません。メインのチェックアウトで実行してください" >&2
    return 1
  fi
  [ "$FORCE" -eq 1 ] && return 0
  if ! git -C "$root" fetch -q origin main; then
    echo "ERROR: origin/main を取得できません。確認のうえ進めるなら --force を付けてください" >&2
    return 1
  fi
  if ! git -C "$root" merge-base --is-ancestor FETCH_HEAD HEAD; then
    echo "ERROR: origin/main を取り込んでいません。チームの変更を上書きするなら --force を付けてください" >&2
    return 1
  fi
}

if [ "$SKIP_DEPLOY" -eq 0 ]; then
  check_deployable || exit 2
fi

mkdir -p "$REPORT_DIR" || exit 2
WORK_DIR="$(mktemp -d)" || exit 2
STAMP="$(date +%Y%m%d-%H%M%S)"
# --skip-deploy では手元のコードとサーバーのコードが一致しない。
if [ "$SKIP_DEPLOY" -eq 0 ]; then
  CODE_LABEL="手元のコード: $(git -C "$SCRIPT_DIR" log -1 --format='%h %s' 2>/dev/null || echo 不明)"
else
  CODE_LABEL="コード: サーバーにあるコード (--skip-deploy)"
fi

# 走行まで進めなかったときも、チームが状況を把握できるように通知する。
abort() {
  local message="$1" code="$2" log="$3" saved="$REPORT_DIR/flow-$STAMP-aborted.md"
  cp "$log" "$saved"
  echo "ERROR: $message (ログ: $saved)" >&2
  notify "❌ flow: $message"$'\n'"$CODE_LABEL" "$saved" \
    || echo "ERROR: Discord に通知できませんでした" >&2
  exit "$code"
}

if [ "$SKIP_DEPLOY" -eq 0 ]; then
  echo "==> [1/6] デプロイ"
  bash "$PROVISIONING_DIR/deploy.sh" 2>&1 | tee "$WORK_DIR/deploy.log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || abort "デプロイに失敗したのでベンチを実行していません" 1 "$WORK_DIR/deploy.log"
else
  echo "==> [1/6] デプロイをスキップ"
fi

echo "==> [2/6] SQL 統計のリセット"
ssh "${SSH_OPTS[@]}" "$DB_HOST" \
  "sudo -u postgres psql -XAt -v ON_ERROR_STOP=1 -d postgres -c 'SELECT pg_stat_statements_reset()'" \
  > "$WORK_DIR/reset.log" 2>&1 \
  || abort "SQL 統計をリセットできないのでベンチを実行していません" 2 "$WORK_DIR/reset.log"

echo "==> [3/6] ベンチ"
bash "$SCRIPT_DIR/enqueue.sh" 2>&1 | tee "$WORK_DIR/bench.log"
BENCH_CODE="${PIPESTATUS[0]}"

# サーバーのログは走行後75秒で消えるので、走行が終わったらすぐ取る。
echo "==> [4/6] alp"
bash "$PROVISIONING_DIR/alp.sh" fetch 2>&1 | tee "$WORK_DIR/alp.log"
ALP_CODE="${PIPESTATUS[0]}"

echo "==> [5/6] スロークエリ"
bash "$PROVISIONING_DIR/profile_db.sh" > "$WORK_DIR/slowquery.log" 2>&1
SLOW_CODE=$?
cat "$WORK_DIR/slowquery.log"

RESULT_LINE="$(grep -m1 -E '^Job #[0-9]+ status=' "$WORK_DIR/bench.log" || echo '結果を取得できませんでした')"
JOB_ID="$(sed -n 's/^Job #\([0-9]*\) .*/\1/p' <<< "$RESULT_LINE")"
# 走行したコードは enqueue.sh の出力が正しい。
CODE_LINE="$(grep -m1 '^コード: ' "$WORK_DIR/bench.log" || echo "$CODE_LABEL")"
REPORT="$REPORT_DIR/flow-$STAMP${JOB_ID:+-job$JOB_ID}.md"
{
  echo "# $RESULT_LINE"
  echo ""
  echo "$CODE_LINE"
  echo ""
  echo "## スロークエリ (累積実行時間順)"
  echo ""
  echo '```'
  cat "$WORK_DIR/slowquery.log"
  echo '```'
  echo ""
  echo "## alp"
  echo ""
  cat "$WORK_DIR/alp.log"
  echo ""
  echo "## ベンチの出力"
  echo ""
  cat "$WORK_DIR/bench.log"
} > "$REPORT" || exit 2
echo "レポート: $REPORT"

echo "==> [6/6] Discord 通知"
case "$BENCH_CODE" in
  0) MARK="✅" ;;
  *) MARK="❌" ;;
esac
# 通知の本文は 2000 文字までなので、上位5件の統計とクエリの先頭だけを載せる。
TOP_QUERIES="$(grep -A7 '上位20件' "$WORK_DIR/slowquery.log" | tail -n +2 | cut -c1-200)"
CONTENT="$MARK flow: $RESULT_LINE"$'\n'"$CODE_LINE"$'\n'"スロークエリ上位5件 (全文は添付):"$'\n''```'$'\n'"${TOP_QUERIES:-取得できませんでした}"$'\n''```'
notify "$CONTENT" "$REPORT"
NOTIFY_CODE=$?
[ "$NOTIFY_CODE" -eq 0 ] || echo "ERROR: Discord に通知できませんでした" >&2

# 走行の FAIL を優先して返す。
if [ "$BENCH_CODE" -ne 0 ]; then
  exit "$BENCH_CODE"
fi
if [ "$ALP_CODE" -ne 0 ] || [ "$SLOW_CODE" -ne 0 ] || [ "$NOTIFY_CODE" -ne 0 ]; then
  exit 2
fi
