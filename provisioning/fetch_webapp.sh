#!/bin/bash
# fetch_webapp.sh
# asia1 サーバーからローカルの github/isucon2026/webapp/ へコードをrsyncする
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ASIA1_HOST="isucon@57.181.195.208"
REMOTE_DIR="/home/isucon/webapp/"
LOCAL_DIR="$REPO_DIR/webapp/"

echo "==> Fetching webapp from $ASIA1_HOST:$REMOTE_DIR ..."
rsync -avz --progress \
  --exclude='.git' \
  --exclude='._*' \
  --exclude='go/isureal' \
  --exclude='nodejs/node_modules/' \
  --exclude='nodejs/dist/' \
  --exclude='ruby/vendor/' \
  --exclude='python/__pycache__/' \
  --exclude='php/vendor/' \
  --exclude='perl/local/' \
  --exclude='rust/target/' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$ASIA1_HOST:$REMOTE_DIR" \
  "$LOCAL_DIR"

echo "==> Done. Files saved to: $LOCAL_DIR"
