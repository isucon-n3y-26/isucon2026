#!/bin/bash
# setup_server.sh
# 【初回のみ】ローカルのリポジトリを各Appサーバーへ rsync して初期配置する
# 使い方: bash provisioning/setup_server.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REMOTE_REPO_DIR="/home/isucon/isucon2026"

APP_HOSTS=(
  "isucon@57.181.195.208"   # asia1
  "isucon@35.74.6.16"       # europe1
  "isucon@35.74.122.15"     # america1
)

SSH_OPTS="-o StrictHostKeyChecking=no"

for HOST in "${APP_HOSTS[@]}"; do
  echo ""
  echo "========================================="
  echo "==> Setup $HOST ..."
  echo "========================================="

  # ローカルのリポジトリを丸ごとrsync (.git も含めて転送)
  rsync -avz --progress \
    --exclude='webapp/nodejs/node_modules/' \
    --exclude='webapp/ruby/vendor/' \
    --exclude='webapp/python/__pycache__/' \
    --exclude='webapp/php/vendor/' \
    --exclude='webapp/perl/local/' \
    --exclude='webapp/rust/target/' \
    --exclude='webapp/rust/isureal' \
    --exclude='webapp/go/isureal' \
    --exclude='webapp/ruby/.bundle/' \
    -e "ssh $SSH_OPTS" \
    "$REPO_DIR/" \
    "$HOST:$REMOTE_REPO_DIR/"

  echo "--> Done: $HOST"
done

echo ""
echo "========================================="
echo "All servers set up!"
echo "Next: run provisioning/deploy.sh to deploy."
echo "========================================="
