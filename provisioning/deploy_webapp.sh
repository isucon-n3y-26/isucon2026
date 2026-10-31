#!/bin/bash
# deploy_webapp.sh
# ローカルの webapp/ を全Appサーバー (asia1, europe1, america1) へrsyncしてビルド・再起動する
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ===== サーバー設定 =====
APP_HOSTS=(
  "isucon@57.181.195.208"   # asia1
  "isucon@35.74.6.16"       # europe1
  "isucon@35.74.122.15"     # america1
)

LOCAL_DIR="$REPO_DIR/webapp/"
REMOTE_DIR="/home/isucon/webapp/"

SSH_OPTS="-o StrictHostKeyChecking=no"

# ===== rsync & deploy =====
for HOST in "${APP_HOSTS[@]}"; do
  echo ""
  echo "========================================="
  echo "==> Deploying to $HOST ..."
  echo "========================================="

  # 1. rsync (go/ ディレクトリを中心に同期; sql/ public/ も含む)
  echo "--> rsync ..."
  rsync -avz --progress \
    --exclude='.git' \
    --exclude='._*' \
    --exclude='go/isureal' \
    -e "ssh $SSH_OPTS" \
    "$LOCAL_DIR" \
    "$HOST:$REMOTE_DIR"

  # 2. Go アプリをビルド
  echo "--> Building Go app ..."
  ssh $SSH_OPTS "$HOST" "
    set -eu
    cd /home/isucon/webapp/go
    go build -o isureal cmd/isureal/main.go
  "

  # 3. サービス再起動
  echo "--> Restarting isureal-go.service ..."
  ssh $SSH_OPTS "$HOST" "sudo systemctl restart isureal-go.service"

  echo "--> Done: $HOST"
done

echo ""
echo "========================================="
echo "All servers deployed successfully!"
echo "========================================="
