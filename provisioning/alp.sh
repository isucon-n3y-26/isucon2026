#!/bin/bash
# alp.sh
# nginx の JSON アクセスログを全Appサーバーで リセット / 集計 する
#
# 使い方:
#   bash provisioning/alp.sh reset   # ベンチ前に実行
#   bash provisioning/alp.sh show    # ベンチ後に実行
#   bash provisioning/alp.sh fetch   # 全サーバーのログを手元に取って集計する。走行が終わったらすぐ実行する
#
# fetch の終了コード: 0 = 成功、2 = 取得できないログか空のログがある (取れた分は集計して出す)
#
set -eu

ACCESS_LOG="/var/log/nginx/access.json.log"
ALP_VERSION="1.0.21"
SSH_OPTS="-o StrictHostKeyChecking=no"
HOSTS=(
  "asia1 isucon@57.181.195.208"
  "europe1 isucon@35.74.6.16"
  "america1 isucon@35.74.122.15"
)
MATCHING='/api/images/.+,/api/posts/[^/]+/comments,/api/posts/[^/]+/realmojis,/api/posts/[^/]+,/api/users/.+,/api/memories/.+,/api/comments/.+,/api/realmojis/.+,/api/friend-requests/.+,/api/friendships/.+,/api/follows/.+,/api/blocks/.+,/api/admin/users/.+'
ALP_OPTS=(json --sort sum --reverse --output count,method,uri,min,max,sum,avg,p99 --format md -m "$MATCHING" --limit 1000)

# 手元に alp がなければ、サーバーと同じバージョンをキャッシュに入れて使う。
find_alp() {
  if command -v alp; then
    return
  fi
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/isucon2026/alp-$ALP_VERSION"
  if [ ! -x "$dir/alp" ]; then
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
    mkdir -p "$dir"
    curl -fsSL "https://github.com/tkuchiki/alp/releases/download/v$ALP_VERSION/alp_${os}_${arch}.tar.gz" | tar xz -C "$dir" alp
  fi
  echo "$dir/alp"
}

case "${1:-}" in
  reset)
    for ENTRY in "${HOSTS[@]}"; do
      read -r NAME HOST <<< "$ENTRY"
      ssh $SSH_OPTS "$HOST" "sudo truncate -s 0 $ACCESS_LOG"
      echo "$NAME: reset"
    done
    ;;
  show)
    for ENTRY in "${HOSTS[@]}"; do
      read -r NAME HOST <<< "$ENTRY"
      echo ""
      echo "### $NAME"
      echo ""
      ssh $SSH_OPTS "$HOST" "sudo cat $ACCESS_LOG | /usr/local/bin/alp json --sort sum --reverse --output count,method,uri,min,max,sum,avg,p99 --format md -m '$MATCHING' --limit 1000" | head -22
    done
    ;;
  fetch)
    ALP="$(find_alp)"
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT
    PIDS=()
    for ENTRY in "${HOSTS[@]}"; do
      read -r NAME HOST <<< "$ENTRY"
      (
        set -o pipefail
        ssh $SSH_OPTS -o ConnectTimeout=10 "$HOST" "gzip -1 < $ACCESS_LOG" | gunzip > "$WORK_DIR/$NAME" \
          || { rm -f "$WORK_DIR/$NAME"; echo "ERROR: $NAME のログを取得できませんでした" >&2; exit 1; }
      ) &
      PIDS+=("$!")
    done
    FAILED=0
    for PID in "${PIDS[@]}"; do
      wait "$PID" || FAILED=1
    done

    FILES=()
    SERVERS=()
    EMPTY=""
    for ENTRY in "${HOSTS[@]}"; do
      read -r NAME _ <<< "$ENTRY"
      if [ -s "$WORK_DIR/$NAME" ]; then
        FILES+=("$WORK_DIR/$NAME")
        SERVERS+=("$NAME $(wc -l < "$WORK_DIR/$NAME")")
      elif [ -e "$WORK_DIR/$NAME" ]; then
        EMPTY="$EMPTY $NAME"
      fi
    done
    if [ "${#FILES[@]}" -eq 0 ]; then
      echo "ERROR: ログがありません。走行後75秒で消えるので、bash provisioning/bench-bot/enqueue.sh result を見てください" >&2
      exit 2
    fi
    # ログが消えたサーバーを黙って除くと、集計が欠けていることに気づけない。
    for NAME in $EMPTY; do
      echo "ERROR: $NAME のログが空なので、集計に含まれていません。全件は bash provisioning/bench-bot/enqueue.sh result を見てください" >&2
      FAILED=1
    done

    TIMES="$(cat "${FILES[@]}" | grep -o '"time":"[^"]*"' | cut -d'"' -f4 | cut -c12-19 | sort)"
    ERRORS="$(cat "${FILES[@]}" | grep -c '"status":5' || true)"
    SUMMARY="$(printf '%s / ' "${SERVERS[@]}")"
    echo "alp 3サーバー集約 $(sed -n 1p <<< "$TIMES")〜$(sed -n '$p' <<< "$TIMES") UTC / $(cat "${FILES[@]}" | wc -l) リクエスト (${SUMMARY% / }) / 5xx: $ERRORS"
    echo "SSE など走行後も接続が残るリクエストは、切断されるまでログに出ないので含まれません。"
    echo ""
    echo "# 全サーバー"
    echo ""
    cat "${FILES[@]}" | "$ALP" "${ALP_OPTS[@]}"
    for FILE in "${FILES[@]}"; do
      echo ""
      echo "# $(basename "$FILE")"
      echo ""
      "$ALP" "${ALP_OPTS[@]}" < "$FILE"
    done
    exit $(( FAILED * 2 ))
    ;;
  *)
    echo "Usage: $0 reset|show|fetch" >&2
    exit 1
    ;;
esac
