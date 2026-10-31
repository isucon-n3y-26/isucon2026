#!/bin/bash
# enqueue.sh
# asia1 の bench-bot でベンチを実行し、スコア、ベンチのログ、3サーバー集約の alp を標準出力に出す
# 投入から alp が揃うまで約4分かかるので、実行ツールのタイムアウトは10分以上にする
#
# 使い方:
#   bash provisioning/bench-bot/enqueue.sh              # 実行して結果が揃うまで待つ
#   bash provisioning/bench-bot/enqueue.sh result       # 最新の走行の結果を出す
#   bash provisioning/bench-bot/enqueue.sh result 6891  # 指定した走行の結果を出す
#
# 終了コード: 0 = 成功、1 = 走行が FAIL、2 = 結果を取得できない
set -eu

case "${1:-enqueue}:${2:-0}" in
  enqueue:0) ARGS="enqueue" ;;
  result:*[!0-9]*) echo "Usage: $0 [result [job_id]]" >&2; exit 2 ;;
  result:*) ARGS="result ${2:-}" ;;
  *) echo "Usage: $0 [result [job_id]]" >&2; exit 2 ;;
esac

ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 isucon@57.181.195.208 "
  systemctl is-active -q bench-bot.service || { echo 'ERROR: bench-bot.service is not running' >&2; exit 2; }
  python3 -B /home/isucon/bench-bot/bot.py $ARGS
"
