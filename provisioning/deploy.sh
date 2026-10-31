#!/bin/bash
# deploy.sh
# 【通常サイクル】全Appサーバーで git pull → Go ビルド → サービス再起動
#
# 使い方:
#   bash provisioning/deploy.sh           # asia1, europe1, america1 に全デプロイ
#   bash provisioning/deploy.sh asia1     # asia1 だけにデプロイ
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_REPO_DIR="/home/isucon/isucon2026"
REMOTE_WEBAPP_DIR="/home/isucon/webapp"

declare -A HOST_MAP=(
  ["asia1"]="isucon@57.181.195.208"
  ["europe1"]="isucon@35.74.6.16"
  ["america1"]="isucon@35.74.122.15"
)

SSH_OPTS="-o StrictHostKeyChecking=no"

# 引数でサーバーを絞り込めるようにする
if [ $# -ge 1 ]; then
  TARGET_NAMES=("$@")
else
  TARGET_NAMES=("asia1" "europe1" "america1")
fi

for NAME in "${TARGET_NAMES[@]}"; do
  HOST="${HOST_MAP[$NAME]:-}"
  if [ -z "$HOST" ]; then
    echo "ERROR: Unknown server name '$NAME'. Valid: asia1, europe1, america1" >&2
    exit 1
  fi

  echo ""
  echo "========================================="
  echo "==> Deploying to $NAME ($HOST) ..."
  echo "========================================="

  ssh $SSH_OPTS "$HOST" "
    set -eu

    # 1. git pull
    echo '--> git pull ...'
    cd '$REMOTE_REPO_DIR'
    git pull

    # 2. webapp/ を rsync で反映
    echo '--> rsync webapp/ ...'
    rsync -a --delete \
      --exclude='._*' \
      --exclude='go/isureal' \
      '$REMOTE_REPO_DIR/webapp/' \
      '$REMOTE_WEBAPP_DIR/'

    # 3. Go ビルド
    echo '--> Building Go app ...'
    cd '$REMOTE_WEBAPP_DIR/go'
    go build -o isureal cmd/isureal/main.go

    # 4. サービス再起動
    echo '--> Restarting isureal-go.service ...'
    sudo systemctl restart isureal-go.service

    echo '--> Done!'
  "

  echo "==> $NAME OK"
done

echo ""
echo "========================================="
echo "All deployments finished!"
echo "========================================="
