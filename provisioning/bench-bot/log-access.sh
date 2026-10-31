#!/bin/bash
# log-access.sh
# asia1 の bench-bot の SSH 鍵で実行できる操作を、アクセスログの確認・読み取り・消去に限定する
set -eu

LOG=/var/log/nginx/access.json.log
case "${SSH_ORIGINAL_COMMAND:-}" in
  status) echo "$(stat -c %s "$LOG") $(( $(date +%s) - $(stat -c %Y "$LOG") ))" ;;
  read) cat "$LOG" ;;
  clear) sudo -n truncate -s 0 "$LOG" ;;
  *) echo "unsupported operation" >&2; exit 1 ;;
esac
