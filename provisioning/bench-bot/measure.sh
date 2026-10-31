#!/usr/bin/env bash
# measure.sh
# 改善の PR を最新の main にマージした状態で計測し、スコアを GitHub の台帳 issue に tree hash で記録する
# flow.sh を使うので、実行ツールのタイムアウトは1走行につき15分以上にする
#
# 使い方:
#   bash provisioning/bench-bot/measure.sh baseline [--runs N]  # origin/main を計測する
#   bash provisioning/bench-bot/measure.sh pr <番号> [--runs N] [--allow-index-drift]
#                                                               # PR を計測して main の基準と比べる
#   bash provisioning/bench-bot/measure.sh queue <番号>... [--runs N]
#                                                               # PR を順に計測し、結果を PR に投稿する。一時停止中は再開を待つ
#   bash provisioning/bench-bot/measure.sh report <番号>        # 最新の計測結果を PR に投稿する
#   bash provisioning/bench-bot/measure.sh pause [理由]         # 今の走行が終わるまで待って、計測を止める
#   bash provisioning/bench-bot/measure.sh resume               # 計測を再開する (自動の待機も解除する)
#   bash provisioning/bench-bot/measure.sh hold [理由]          # flow.sh が使う。計測の終わりを待って queue を待たせる
#   bash provisioning/bench-bot/measure.sh release-hold         # flow.sh が使う。少し間を置いて queue を再開させる
#   bash provisioning/bench-bot/measure.sh adopt <番号>         # 計測済みの内容のまま PR をマージする
#   bash provisioning/bench-bot/measure.sh show                 # 台帳を表示する
#   bash provisioning/bench-bot/measure.sh indexes              # DB の索引を表示する (パーティションを除く)
#   bash provisioning/bench-bot/measure.sh unlock               # 残った計測ロックを消す
#
# 終了コード: 0 = 成功、1 = 走行が FAIL、2 = それ以外の失敗、3 = 前提を満たさず計測していない

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" || exit 2
ORIGIN_URL="$(git -C "$SOURCE_ROOT" remote get-url origin)" || exit 2
# worktree の親ではなく、メインのチェックアウトの隣に置く。
COMMON_DIR="$(git -C "$SOURCE_ROOT" rev-parse --path-format=absolute --git-common-dir)" || exit 2
CLONE_DIR="${MEASURE_CLONE_DIR:-$(dirname "$(dirname "$COMMON_DIR")")/isucon2026-deploy}"
ASIA1="isucon@57.181.195.208"
DB_HOST="isucon@54.65.131.246"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15)
LOCK_DIR="/tmp/isucon2026-measure.lock"
PAUSE_FILE="/tmp/isucon2026-measure.pause"
# 中身は「この時刻まで待たせる epoch 理由」。flow.sh が異常終了しても期限で解除される。
HOLD_FILE="/tmp/isucon2026-measure.hold"
HOLD_SECONDS="${MEASURE_HOLD_SECONDS:-1800}"
# チームメイトは続けて走らせることが多いので、終わってもしばらく待つ。
COOLDOWN_SECONDS="${MEASURE_COOLDOWN_SECONDS:-300}"
SERVER_HOME="/home/isucon"
PAUSE_POLL="${MEASURE_PAUSE_POLL:-15}"
PAUSE_TIMEOUT="${MEASURE_PAUSE_TIMEOUT:-900}"
# この割合より伸びたら改善と判定する。
IMPROVE_PCT="${MEASURE_IMPROVE_PCT:-3}"
LEDGER_TITLE="スコア台帳"
LEDGER_MARK="<!-- measure:"
# サーバーのログは走行後75秒で消えるので、続けて走らせるときはログが混ざらないように待つ。
RUN_INTERVAL="${MEASURE_RUN_INTERVAL:-80}"
LOCK_HELD=0

die() {
  local code="$1"
  shift
  echo "ERROR: $*" >&2
  exit "$code"
}

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] && ssh "${SSH_OPTS[@]}" "$ASIA1" "rm -rf '$LOCK_DIR'"
  LOCK_HELD=0
}

# デプロイからベンチまでをチームの間で直列にするので、ロックは共有サーバーに置く。
acquire_lock() {
  local owner="$(id -un)@$(hostname) $(date '+%H:%M:%S') $1"
  if ! ssh "${SSH_OPTS[@]}" "$ASIA1" "mkdir '$LOCK_DIR' && printf '%s\n' '$owner' > '$LOCK_DIR/owner'" 2>/dev/null; then
    die 3 "計測中です: $(ssh "${SSH_OPTS[@]}" "$ASIA1" "cat '$LOCK_DIR/owner'" 2>/dev/null || echo 不明)。残っているだけなら measure.sh unlock"
  fi
  LOCK_HELD=1
  trap release_lock EXIT
  trap 'exit 130' INT TERM
  # pause はロックが空くのを待つので、取得の後に確かめれば行き違いがない。
  local reason
  reason="$(read_pause)"
  if [ -n "$reason" ]; then
    release_lock
    die 3 "一時停止中です: $reason"
  fi
}

# 止める理由があれば出す。flow.sh を通さないデプロイは、未コミットの変更と直近のビルドで検知する。
read_pause() {
  ssh "${SSH_OPTS[@]}" "$ASIA1" "
    cat '$PAUSE_FILE' 2>/dev/null
    if [ -f '$HOLD_FILE' ]; then
      read -r until reason < '$HOLD_FILE'
      [ \"\$(date +%s)\" -lt \"\$until\" ] && echo \"\$reason\"
    fi
    if [ -n \"\$(git -C '$SERVER_HOME/isucon2026' status --porcelain --untracked-files=no -- webapp provisioning 2>/dev/null)\" ] \
      && [ -n \"\$(find '$SERVER_HOME/webapp/go/isureal' -mmin -$((COOLDOWN_SECONDS / 60)) 2>/dev/null)\" ]; then
      echo '手元の変更が直近にデプロイされています'
    fi
  " 2>/dev/null | head -n 1 || true
}

# 一時停止していなければすぐ戻る。待ったときだけ 0 を返す。
wait_unpaused() {
  local reason waited=1
  while reason="$(read_pause)"; [ -n "$reason" ]; do
    [ "$waited" -eq 1 ] && echo "==> 一時停止中です: $reason。再開を待ちます"
    waited=0
    sleep "$PAUSE_POLL"
  done
  return "$waited"
}

prepare_clone() {
  if [ ! -d "$CLONE_DIR/.git" ]; then
    git clone -q "$ORIGIN_URL" "$CLONE_DIR" || die 2 "$CLONE_DIR に clone できません"
  fi
  git -C "$CLONE_DIR" fetch -q --prune origin || die 2 "origin を取得できません"
  git -C "$CLONE_DIR" merge --abort 2>/dev/null
  git -C "$CLONE_DIR" checkout -q --force --detach origin/main || die 2 "origin/main に切り替えられません"
  git -C "$CLONE_DIR" clean -qfd || die 2 "$CLONE_DIR を掃除できません"
}

find_ledger() {
  (cd "$CLONE_DIR" && gh issue list --state open --search "$LEDGER_TITLE in:title" --json number,title \
    --jq "map(select(.title == \"$LEDGER_TITLE\")) | .[0].number // empty")
}

# 台帳がなければ作る。
ensure_ledger() {
  local number
  number="$(find_ledger)" || die 2 "台帳の issue を検索できません"
  if [ -z "$number" ]; then
    number="$(cd "$CLONE_DIR" && gh issue create --title "$LEDGER_TITLE" \
      --body "measure.sh が tree hash ごとのスコアを記録します。手で編集しないでください。" | sed -n 's#.*/issues/\([0-9]*\)$#\1#p')"
    [ -n "$number" ] || die 2 "台帳の issue を作れません"
    (cd "$CLONE_DIR" && gh issue pin "$number" >/dev/null 2>&1) || echo "WARN: 台帳の issue をピン留めできませんでした" >&2
  fi
  echo "$number"
}

# 記録を1行1 JSON で出す。台帳がなければ何も出さない。
read_entries() {
  local number
  number="$(find_ledger)" || return 1
  [ -n "$number" ] || return 0
  (cd "$CLONE_DIR" && gh api --paginate "repos/{owner}/{repo}/issues/$number/comments" --jq '.[].body') \
    | sed -n "s/^$LEDGER_MARK\(.*\) -->\$/\1/p"
}

# 通過した走行のスコアの中央値。走行がなければ何も出さない。
median_score() {
  jq -r --arg tree "$2" 'select(.tree == $tree and .passed == true) | .score' <<< "$1" \
    | sort -n | awk '{ v[NR] = $1 } END { if (NR) print (NR % 2 ? v[(NR + 1) / 2] : int((v[NR / 2] + v[NR / 2 + 1]) / 2)) }'
}

score_range() {
  jq -r --arg tree "$2" 'select(.tree == $tree and .passed == true) | .score' <<< "$1" \
    | sort -n | awk 'NR == 1 { min = $1 } { max = $1 } END { if (NR) printf "%s〜%s (%d回)", min, max, NR }'
}

# 走行で変わらなければ比較できる。パーティションの索引も含めて全体を見る。
index_fingerprint() {
  ssh "${SSH_OPTS[@]}" "$DB_HOST" "sudo -u postgres psql -XAt -v ON_ERROR_STOP=1 -d isureal -c \"SELECT md5(string_agg(indexdef, E'\\n' ORDER BY indexdef)) FROM pg_indexes WHERE schemaname = 'public'\""
}

list_indexes() {
  ssh "${SSH_OPTS[@]}" "$DB_HOST" "sudo -u postgres psql -XAt -v ON_ERROR_STOP=1 -d isureal -c \"SELECT tablename || ' ' || indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename NOT LIKE 'image_objects_%' ORDER BY 1\""
}

# flow.sh を実行して台帳に記録する。結果は RUN_SCORE と RUN_PASSED に入れる。
run_once() {
  local kind="$1" pr="$2" skip_deploy="$3" ledger="$4"
  local log commit tree base_tree result job status passed score code flow_code fingerprint entry args=()
  log="$(mktemp)" || die 2 "一時ファイルを作れません"
  [ "$skip_deploy" -eq 1 ] && args+=(--skip-deploy)
  commit="$(git -C "$CLONE_DIR" rev-parse HEAD)"
  tree="$(git -C "$CLONE_DIR" rev-parse 'HEAD^{tree}')"
  base_tree="$(git -C "$CLONE_DIR" rev-parse 'origin/main^{tree}')"

  MEASURE_RUN=1 bash "$CLONE_DIR/provisioning/bench-bot/flow.sh" ${args[@]+"${args[@]}"} 2>&1 | tee "$log"
  flow_code="${PIPESTATUS[0]}"

  result="$(grep -m1 -E '^Job #[0-9]+ status=' "$log")"
  [ -n "$result" ] || { rm -f "$log"; die 2 "走行の結果がありません (flow.sh の終了コード: $flow_code)。記録していません"; }
  job="$(sed -n 's/^Job #\([0-9]*\) .*/\1/p' <<< "$result")"
  status="$(sed -n 's/.* status=\([^ ]*\).*/\1/p' <<< "$result")"
  passed="$(sed -n 's/.* passed=\([^ ]*\).*/\1/p' <<< "$result")"
  score="$(sed -n 's/.* score=\([^ ]*\).*/\1/p' <<< "$result")"
  code="$(grep -m1 '^コード: ' "$log" | sed 's/^コード: //')"
  rm -f "$log"

  # 走行中に他の人がデプロイすると、別のコードのスコアになる。
  if [ "${code%% *}" = "" ] || [ "${commit#"${code%% *}"}" = "$commit" ] || [[ "$code" == *未コミット* ]]; then
    die 2 "Job #$job はこの計測のコードで走っていません (サーバー: ${code:-不明} / 計測: ${commit:0:7})。記録していません"
  fi
  [[ "$score" =~ ^-?[0-9]+$ ]] || die 2 "Job #$job のスコアを読めません: $result"

  fingerprint="$(index_fingerprint)" || die 2 "DB の索引を確認できません。記録していません"
  [ "$passed" = "true" ] && passed=true || passed=false
  entry="$(jq -cn --arg kind "$kind" --arg pr "$pr" --arg tree "$tree" --arg base_tree "$base_tree" --arg commit "$commit" \
    --arg job "$job" --arg status "$status" --argjson passed "$passed" --argjson score "$score" \
    --arg indexes "$fingerprint" --arg at "$(date -Iseconds)" \
    '{kind: $kind, pr: $pr, tree: $tree, base_tree: $base_tree, commit: $commit, job: $job, status: $status, passed: $passed, score: $score, indexes: $indexes, at: $at}')"
  printf '%s%s -->\n| %s | %s | tree `%s` | Job #%s | score **%s** | passed=%s |\n' \
    "$LEDGER_MARK" "$entry" "$(date '+%H:%M:%S')" "$([ -n "$pr" ] && echo "PR #$pr" || echo main)" "${tree:0:10}" "$job" "$score" "$passed" \
    | (cd "$CLONE_DIR" && gh issue comment "$ledger" --body-file - >/dev/null) \
    || die 2 "台帳に記録できません (Job #$job score=$score)"

  RUN_SCORE="$score"
  RUN_PASSED="$passed"
}

# run_once を繰り返す。2回目以降はデプロイしない。
run_series() {
  local kind="$1" pr="$2" runs="$3" ledger="$4" i skip_deploy
  ANY_FAILED=0
  for ((i = 1; i <= runs; i++)); do
    skip_deploy=0
    if [ "$i" -gt 1 ]; then
      sleep "$RUN_INTERVAL"
      skip_deploy=1
      # 止めている間に他の人がデプロイするので、再開後はデプロイし直す。
      if [ -n "$(read_pause)" ]; then
        release_lock
        wait_unpaused
        acquire_lock "$kind $pr"
        skip_deploy=0
      fi
    fi
    echo "==> 計測 $i/$runs"
    run_once "$kind" "$pr" "$skip_deploy" "$ledger"
    [ "$RUN_PASSED" = "true" ] || ANY_FAILED=1
  done
}

cmd_baseline() {
  local runs=1 ledger tree entries
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs) runs="${2:-}"; shift 2 ;;
      *) die 2 "不明な引数: $1" ;;
    esac
  done
  [[ "$runs" =~ ^[1-9][0-9]*$ ]] || die 2 "--runs には1以上の数を指定してください"
  acquire_lock "baseline"
  prepare_clone
  ledger="$(ensure_ledger)" || exit 2
  echo "==> DB の索引 (reset.sql は索引を消さないので、却下した PR の索引が残っていないか確認してください)"
  list_indexes || die 2 "DB の索引を確認できません"
  run_series main "" "$runs" "$ledger"
  tree="$(git -C "$CLONE_DIR" rev-parse 'HEAD^{tree}')"
  entries="$(read_entries)" || die 2 "台帳を読めません"
  echo ""
  echo "main tree ${tree:0:10}: 中央値 $(median_score "$entries" "$tree") / $(score_range "$entries" "$tree")"
  [ "$ANY_FAILED" -eq 0 ] || exit 1
}

cmd_pr() {
  local number="${1:-}" runs=1 allow_drift=0 head state ledger base_tree tree entries base_median expected current median
  [[ "$number" =~ ^[0-9]+$ ]] || die 2 "PR の番号を指定してください"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs) runs="${2:-}"; shift 2 ;;
      --allow-index-drift) allow_drift=1; shift ;;
      *) die 2 "不明な引数: $1" ;;
    esac
  done
  [[ "$runs" =~ ^[1-9][0-9]*$ ]] || die 2 "--runs には1以上の数を指定してください"
  acquire_lock "PR #$number"
  prepare_clone
  head="$(cd "$CLONE_DIR" && gh pr view "$number" --json headRefName --jq .headRefName)" || die 2 "PR #$number を取得できません"
  state="$(cd "$CLONE_DIR" && gh pr view "$number" --json state --jq .state)" || die 2 "PR #$number を取得できません"
  [ "$state" = "OPEN" ] || die 3 "PR #$number は $state です"
  ledger="$(ensure_ledger)" || exit 2

  base_tree="$(git -C "$CLONE_DIR" rev-parse 'origin/main^{tree}')"
  entries="$(read_entries)" || die 2 "台帳を読めません"
  base_median="$(median_score "$entries" "$base_tree")"
  [ -n "$base_median" ] || die 3 "今の main (tree ${base_tree:0:10}) のスコアがありません。先に measure.sh baseline を実行してください"

  # 却下した PR の索引は reset.sql では消えないので、基準と条件が揃っているか確かめる。
  expected="$(jq -r --arg tree "$base_tree" 'select(.tree == $tree and .passed == true) | .indexes' <<< "$entries" | tail -n 1)"
  current="$(index_fingerprint)" || die 2 "DB の索引を確認できません"
  if [ "$current" != "$expected" ] && [ "$allow_drift" -eq 0 ]; then
    list_indexes >&2
    die 3 "DB の索引が main の計測時と違います。却下した PR の索引が残っていないか確認してください (比べずに進めるなら --allow-index-drift)"
  fi

  git -C "$CLONE_DIR" fetch -q origin "$head" || die 2 "ブランチ $head を取得できません"
  # GitHub のマージと同じ tree にする。こうすると計測結果がマージ後の main の基準になる。
  if ! git -C "$CLONE_DIR" -c user.name=measure -c user.email=measure@localhost merge -q --no-ff --no-edit -m "measure: PR #$number ($head)" FETCH_HEAD; then
    git -C "$CLONE_DIR" merge --abort
    die 3 "PR #$number は main と衝突しています。ブランチで解消してください"
  fi
  tree="$(git -C "$CLONE_DIR" rev-parse 'HEAD^{tree}')"
  [ "$tree" != "$base_tree" ] || die 3 "PR #$number をマージしても main と同じ内容です"

  run_series pr "$number" "$runs" "$ledger"
  entries="$(read_entries)" || die 2 "台帳を読めません"
  median="$(median_score "$entries" "$tree")"
  echo ""
  echo "main  tree ${base_tree:0:10}: 中央値 $base_median / $(score_range "$entries" "$base_tree")"
  echo "PR #$number tree ${tree:0:10}: 中央値 ${median:-なし} / $(score_range "$entries" "$tree")"
  if [ -n "$median" ]; then
    awk -v a="$median" -v b="$base_median" 'BEGIN { printf "差分: %+d", a - b; if (b != 0) printf " (%+.1f%%)", (a - b) * 100 / b; print "" }'
  fi
  [ "$ANY_FAILED" -eq 0 ] || exit 1
}

# 改善なら PR の本文に、改善しなければコメントに結果を書く。採否は人が決める。
cmd_report() {
  local number="${1:-}" entries last tree base_tree passed job score base_median base_range median range verdict delta text body new_body
  [[ "$number" =~ ^[0-9]+$ ]] || die 2 "PR の番号を指定してください"
  [ -d "$CLONE_DIR/.git" ] || prepare_clone
  entries="$(read_entries)" || die 2 "台帳を読めません"
  last="$(jq -c --arg pr "$number" 'select(.pr == $pr)' <<< "$entries" | tail -n 1)"
  [ -n "$last" ] || die 3 "PR #$number の計測がありません"
  tree="$(jq -r .tree <<< "$last")"
  base_tree="$(jq -r .base_tree <<< "$last")"
  passed="$(jq -r .passed <<< "$last")"
  job="$(jq -r .job <<< "$last")"
  score="$(jq -r .score <<< "$last")"
  base_median="$(median_score "$entries" "$base_tree")"
  [ -n "$base_median" ] || die 3 "基準 (tree ${base_tree:0:10}) のスコアがありません"
  base_range="$(score_range "$entries" "$base_tree")"
  median="$(median_score "$entries" "$tree")"
  range="$(score_range "$entries" "$tree")"

  if [ "$passed" != "true" ] || [ -z "$median" ]; then
    verdict="FAIL"
  else
    verdict="$(awk -v a="$median" -v b="$base_median" -v p="$IMPROVE_PCT" 'BEGIN { print (b > 0 && (a - b) * 100 / b >= p) ? "改善" : "改善せず" }')"
    delta="$(awk -v a="$median" -v b="$base_median" 'BEGIN { printf "%+d", a - b; if (b != 0) printf " (%+.1f%%)", (a - b) * 100 / b }')"
  fi
  text="$(cat <<EOF
## 計測結果: $verdict

| | 中央値 | 範囲 |
|---|---|---|
| main (tree \`${base_tree:0:10}\`) | $base_median | $base_range |
| PR (tree \`${tree:0:10}\`) | ${median:-なし} | ${range:-なし} |

- 差分: ${delta:-なし}
- 最新の走行: Job #$job score=$score passed=$passed
- 判定の基準: FAIL がなく、中央値が main より ${IMPROVE_PCT}% 以上伸びたら改善。採否は人が決めます
EOF
)"
  body="$(cd "$CLONE_DIR" && gh pr view "$number" --json body --jq .body)" || die 2 "PR #$number の本文を取得できません"
  # 前回の結果は消して、最新の判定だけを本文に残す。
  new_body="$(sed '/^<!-- measure-result -->$/,/^<!-- \/measure-result -->$/d' <<< "$body")"
  if [ "$verdict" = "改善" ]; then
    new_body="$(printf '%s\n\n<!-- measure-result -->\n%s\n<!-- /measure-result -->' "$new_body" "$text")"
  else
    printf '%s\n' "$text" | (cd "$CLONE_DIR" && gh pr comment "$number" --body-file - >/dev/null) \
      || die 2 "PR #$number にコメントできません"
  fi
  if [ "$new_body" != "$body" ]; then
    printf '%s\n' "$new_body" | (cd "$CLONE_DIR" && gh api -X PATCH "repos/{owner}/{repo}/pulls/$number" -F body=@- >/dev/null) \
      || die 2 "PR #$number の本文を更新できません"
  fi
  echo "PR #$number: $verdict ${delta:-} (Job #$job)"
}

cmd_queue() {
  local numbers=() options=() number code index
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs) options+=(--runs "${2:-}"); shift 2 ;;
      *) [[ "$1" =~ ^[0-9]+$ ]] || die 2 "不明な引数: $1"; numbers+=("$1"); shift ;;
    esac
  done
  [ "${#numbers[@]}" -gt 0 ] || die 2 "PR の番号を指定してください"
  index=0
  while [ "$index" -lt "${#numbers[@]}" ]; do
    number="${numbers[$index]}"
    wait_unpaused
    echo "==> PR #$number を計測します"
    (cmd_pr "$number" ${options[@]+"${options[@]}"})
    code=$?
    # 開始の直前に止められたら、同じ PR を再開後に計測する。
    if [ "$code" -eq 3 ] && [ -n "$(read_pause)" ]; then
      continue
    fi
    if [ "$code" -ne 0 ] && [ "$code" -ne 1 ]; then
      die "$code" "PR #$number で止まりました。未計測: ${numbers[*]:$index}"
    fi
    cmd_report "$number" || exit $?
    index=$((index + 1))
  done
  echo "すべて計測しました: ${numbers[*]}"
}

cmd_pause() {
  local reason="${1:-理由なし}" waited=0
  reason="${reason//\'/}"
  ssh "${SSH_OPTS[@]}" "$ASIA1" "printf '%s\n' '$(id -un) $(date '+%H:%M:%S') $reason' > '$PAUSE_FILE'" || die 2 "一時停止を設定できません"
  while ssh "${SSH_OPTS[@]}" "$ASIA1" "test -d '$LOCK_DIR'"; do
    [ "$waited" -eq 0 ] && echo "今の走行が終わるのを待っています"
    [ "$waited" -lt "$PAUSE_TIMEOUT" ] || die 2 "ロックが残っています。計測中か measure.sh show で確かめてください"
    sleep "$PAUSE_POLL"
    waited=$((waited + PAUSE_POLL))
  done
  echo "計測を止めました。終わったら measure.sh resume を実行してください"
}

write_hold() {
  local seconds="$1" reason="${2//\'/}"
  ssh "${SSH_OPTS[@]}" "$ASIA1" "printf '%s %s\\n' \"\$((\$(date +%s) + $seconds))\" '$reason' > '$HOLD_FILE'"
}

cmd_hold() {
  local reason="${1:-$(id -un) の flow.sh}" waited=0
  write_hold "$HOLD_SECONDS" "$reason" || die 2 "待機を設定できません"
  while ssh "${SSH_OPTS[@]}" "$ASIA1" "test -d '$LOCK_DIR'"; do
    [ "$waited" -eq 0 ] && echo "PR の計測が終わるのを待っています (1走行あたり数分)"
    [ "$waited" -lt "$PAUSE_TIMEOUT" ] || die 2 "計測のロックが残っています"
    sleep "$PAUSE_POLL"
    waited=$((waited + PAUSE_POLL))
  done
}

cmd_adopt() {
  local number="${1:-}" head state tree entries median main_tree
  [[ "$number" =~ ^[0-9]+$ ]] || die 2 "PR の番号を指定してください"
  prepare_clone
  head="$(cd "$CLONE_DIR" && gh pr view "$number" --json headRefName --jq .headRefName)" || die 2 "PR #$number を取得できません"
  state="$(cd "$CLONE_DIR" && gh pr view "$number" --json state --jq .state)" || die 2 "PR #$number を取得できません"
  [ "$state" = "OPEN" ] || die 3 "PR #$number は $state です"
  git -C "$CLONE_DIR" fetch -q origin "$head" || die 2 "ブランチ $head を取得できません"
  tree="$(git -C "$CLONE_DIR" merge-tree --write-tree origin/main FETCH_HEAD)" || die 3 "PR #$number は main と衝突しています"
  entries="$(read_entries)" || die 2 "台帳を読めません"
  median="$(median_score "$entries" "$tree")"
  [ -n "$median" ] || die 3 "今の main にマージした内容 (tree ${tree:0:10}) は未計測です。measure.sh pr $number を実行してください"
  (cd "$CLONE_DIR" && gh pr merge "$number" --merge) || die 2 "PR #$number をマージできません"
  git -C "$CLONE_DIR" fetch -q origin main || die 2 "origin/main を取得できません"
  main_tree="$(git -C "$CLONE_DIR" rev-parse 'origin/main^{tree}')"
  if [ "$main_tree" != "$tree" ]; then
    die 2 "マージ後の main (tree ${main_tree:0:10}) が計測した内容と違います。measure.sh baseline を実行してください"
  fi
  echo "PR #$number をマージしました。main の基準は tree ${tree:0:10} の中央値 $median です"
}

cmd_show() {
  local entries
  [ -d "$CLONE_DIR/.git" ] || prepare_clone
  entries="$(read_entries)" || die 2 "台帳を読めません"
  [ -n "$entries" ] || { echo "記録はありません"; return 0; }
  jq -r '[.at[11:19], (if .kind == "pr" then "PR #" + .pr else "main" end), .tree[0:10], "Job #" + .job, (.score | tostring), (if .passed then "passed" else "FAIL" end)] | @tsv' <<< "$entries"
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift
case "$COMMAND" in
  baseline) cmd_baseline "$@" ;;
  pr) cmd_pr "$@" ;;
  queue) cmd_queue "$@" ;;
  report) cmd_report "$@" ;;
  pause) cmd_pause "$@" ;;
  resume) ssh "${SSH_OPTS[@]}" "$ASIA1" "rm -f '$PAUSE_FILE' '$HOLD_FILE'" && echo "計測を再開しました" ;;
  hold) cmd_hold "$@" ;;
  release-hold) write_hold "$COOLDOWN_SECONDS" "$(id -un) の flow.sh の直後" ;;
  adopt) cmd_adopt "$@" ;;
  show) cmd_show ;;
  indexes) list_indexes ;;
  unlock) ssh "${SSH_OPTS[@]}" "$ASIA1" "rm -rf '$LOCK_DIR'" ;;
  *) sed -n '5,18p' "$0" >&2; exit 2 ;;
esac
