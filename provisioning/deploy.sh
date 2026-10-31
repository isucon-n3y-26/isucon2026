#!/bin/bash
# deploy.sh
# 【通常サイクル】全Appサーバーで git pull → Go ビルド → サービス再起動 → ヘルスチェック
#
# 使い方:
#   bash provisioning/deploy.sh           # asia1, europe1, america1 に全デプロイ
#   bash provisioning/deploy.sh asia1     # asia1 だけにデプロイ
#
# デプロイ完了後:
#   ポータルからベンチマークを実行する: https://portal.isucon.net/contestant
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

  # ローカルの最新状態をサーバーへ差分rsync
  echo "--> rsync repo ..."
  rsync -az \
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
    "$SCRIPT_DIR/../" \
    "$HOST:$REMOTE_REPO_DIR/"

  ssh $SSH_OPTS "$HOST" "
    set -eu

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
    /home/isucon/local/go/bin/go build -o isureal cmd/isureal/main.go

    # 4. サービス再起動
    echo '--> Restarting isureal-go.service ...'
    sudo systemctl restart isureal-go.service

    echo '--> Done!'
  "

  echo "==> $NAME deploy OK"
done

echo ""
echo "========================================="
echo "All deployments finished!"
echo "========================================="

# ===== デプロイ後ヘルスチェック =====
echo ""
echo "========================================="
echo "==> Post-deploy health check ..."
echo "========================================="

FAILED_HOSTS=()
for NAME in "${TARGET_NAMES[@]}"; do
  HOST="${HOST_MAP[$NAME]}"
  echo ""
  echo "--> Checking $NAME ($HOST) ..."

  # isureal-go.service の状態確認
  SVC_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active isureal-go.service" 2>/dev/null || echo "unknown")
  if [ "$SVC_STATUS" != "active" ]; then
    echo "    [FAIL] isureal-go.service is '$SVC_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u isureal-go.service -n 50 --no-pager'"
    FAILED_HOSTS+=("$NAME")
    continue
  fi
  echo "    [OK]   isureal-go.service is active"

  # nginx.service の状態確認
  NGX_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active nginx.service" 2>/dev/null || echo "unknown")
  if [ "$NGX_STATUS" != "active" ]; then
    echo "    [FAIL] nginx.service is '$NGX_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u nginx.service -n 20 --no-pager'"
    FAILED_HOSTS+=("$NAME")
    continue
  fi
  echo "    [OK]   nginx.service is active"

  # HTTP ヘルスチェック (サーバー上の localhost 経由)
  HTTP_STATUS=$(ssh $SSH_OPTS "$HOST" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost/" \
    2>/dev/null || echo "000")
  case "$HTTP_STATUS" in
    200|301|302|304)
      echo "    [OK]   HTTP $HTTP_STATUS from localhost"
      ;;
    000)
      echo "    [FAIL] HTTP timeout or connection refused"
      FAILED_HOSTS+=("$NAME")
      continue
      ;;
    *)
      echo "    [WARN] HTTP $HTTP_STATUS from localhost (may be OK)"
      ;;
  esac
done

echo ""
echo "========================================="
if [ ${#FAILED_HOSTS[@]} -gt 0 ]; then
  echo "[FAIL] Health check failed on: ${FAILED_HOSTS[*]}"
  echo ""
  echo "Troubleshooting:"
  for NAME in "${FAILED_HOSTS[@]}"; do
    H="${HOST_MAP[$NAME]}"
    echo "  ssh $H 'journalctl -u isureal-go.service -n 50 --no-pager'"
  done
  echo "========================================="
  exit 1
else
  echo "[OK] All health checks passed!"
  echo ""
  echo "Next: Run benchmark from the portal"
  echo "  https://portal.isucon.net/contestant"
  echo "========================================="
fi
