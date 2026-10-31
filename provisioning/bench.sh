#!/usr/bin/env bash
# 全サーバーへデプロイしてからベンチマークを実行する。処理は bench-bot/flow.sh にまとめている。
# 使い方: bash provisioning/bench.sh [--skip-deploy] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec bash "$SCRIPT_DIR/bench-bot/flow.sh" "$@"
