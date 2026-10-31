#!/bin/bash
# enqueue.sh
# asia1 の bench-bot にベンチの実行を要求する
# 投入、結果確認、alp の取得、Discord への通知はサーバー側で行う
#
# 使い方:
#   bash provisioning/bench-bot/enqueue.sh
#
set -eu

ssh -o StrictHostKeyChecking=no isucon@57.181.195.208 '
  set -eu
  if ! systemctl is-active -q bench-bot.service; then
    echo "ERROR: bench-bot.service is not running" >&2
    exit 1
  fi
  touch /home/isucon/bench-bot/enqueue.request
'
echo "ベンチの実行を要求しました。結果は Discord に通知されます。"
