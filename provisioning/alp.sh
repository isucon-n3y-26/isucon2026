#!/bin/bash
# alp.sh
# nginx の JSON アクセスログを全Appサーバーで リセット / 集計 する
#
# 使い方:
#   bash provisioning/alp.sh reset   # ベンチ前に実行
#   bash provisioning/alp.sh show    # ベンチ後に実行
#
set -eu

ACCESS_LOG="/var/log/nginx/access.json.log"
SSH_OPTS="-o StrictHostKeyChecking=no"
HOSTS=(
  "asia1 isucon@57.181.195.208"
  "europe1 isucon@35.74.6.16"
  "america1 isucon@35.74.122.15"
)
MATCHING='/api/images/.+,/api/posts/[^/]+/comments,/api/posts/[^/]+/realmojis,/api/posts/[^/]+,/api/users/.+,/api/memories/.+,/api/comments/.+,/api/realmojis/.+,/api/friend-requests/.+,/api/friendships/.+,/api/follows/.+,/api/blocks/.+,/api/admin/users/.+'

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
  *)
    echo "Usage: $0 reset|show" >&2
    exit 1
    ;;
esac
