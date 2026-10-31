#!/usr/bin/env bash
# 全サーバーへデプロイしてからベンチマークを実行する。
# 使い方: bash provisioning/bench.sh

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Deploying to all app servers and syncing the DB config ..."
bash "$SCRIPT_DIR/deploy.sh"

echo "==> Starting the benchmark and waiting for results ..."
bash "$SCRIPT_DIR/bench-bot/enqueue.sh"
