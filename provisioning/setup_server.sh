#!/bin/bash
# setup_server.sh
# 【初回のみ】各Appサーバーに GitHub リポジトリを clone する
# 使い方: bash provisioning/setup_server.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_URL="https://github.com/isucon-n3y-26/isucon2026.git"
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

  ssh $SSH_OPTS "$HOST" "
    set -eu
    if [ -d '$REMOTE_REPO_DIR/.git' ]; then
      echo 'Repo already exists, skipping clone.'
    else
      git clone '$REPO_URL' '$REMOTE_REPO_DIR'
      echo 'Clone done.'
    fi
  "

  echo "--> Done: $HOST"
done

echo ""
echo "========================================="
echo "All servers set up!"
echo "Next: run provisioning/deploy.sh to deploy."
echo "========================================="
