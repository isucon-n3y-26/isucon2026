#!/bin/bash
# bench.sh
# デプロイ後のヘルスチェックを実行し、ベンチマーク実行をポータルへ案内するスクリプト。
#
# 使い方:
#   bash webapp/bench.sh                  # asia1, europe1, america1 を全チェック
#   bash webapp/bench.sh asia1            # asia1 だけをチェック
#
# ベンチマーク実行はポータルから:
#   https://portal.isucon.net/contestant
#
set -eu

declare -A HOST_MAP=(
  ["asia1"]="isucon@57.181.195.208"
  ["europe1"]="isucon@35.74.6.16"
  ["america1"]="isucon@35.74.122.15"
)

SSH_OPTS="-o StrictHostKeyChecking=no"

if [ $# -ge 1 ]; then
  TARGET_NAMES=("$@")
else
  TARGET_NAMES=("asia1" "europe1" "america1")
fi

echo "========================================="
echo "==> Post-deploy health check"
echo "========================================="

FAILED_HOSTS=()
for NAME in "${TARGET_NAMES[@]}"; do
  HOST="${HOST_MAP[$NAME]:-}"
  if [ -z "$HOST" ]; then
    echo "ERROR: Unknown server name '$NAME'. Valid: asia1, europe1, america1" >&2
    exit 1
  fi

  echo ""
  echo "--> Checking $NAME ($HOST) ..."

  # isureal-go.service の状態確認
  SVC_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active isureal-go.service" 2>/dev/null || echo "unknown")
  if [ "$SVC_STATUS" != "active" ]; then
    echo "    [FAIL] isureal-go.service is '$SVC_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u isureal-go.service -n 50'"
    FAILED_HOSTS+=("$NAME")
    continue
  fi
  echo "    [OK]   isureal-go.service is active"

  # nginx.service の状態確認
  NGX_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active nginx.service" 2>/dev/null || echo "unknown")
  if [ "$NGX_STATUS" != "active" ]; then
    echo "    [FAIL] nginx.service is '$NGX_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u nginx.service -n 20'"
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
    HOST="${HOST_MAP[$NAME]}"
    echo "  ssh $HOST 'journalctl -u isureal-go.service -n 50 --no-pager'"
  done
  exit 1
else
  echo "[OK] All health checks passed!"
  echo ""
  echo "Next: Run benchmark from the portal"
  echo "  https://portal.isucon.net/contestant"
fi
echo "========================================="
