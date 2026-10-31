#!/bin/bash
# deploy.sh
# 【通常サイクル】全Appサーバーで git pull → Go ビルド → サービス再起動 → ヘルスチェック
#
# 使い方:
#   bash provisioning/deploy.sh           # asia1, europe1, america1 と DB 設定をデプロイ
#   bash provisioning/deploy.sh asia1     # asia1 と DB 設定をデプロイ
#   bash provisioning/deploy.sh db       # DB 設定だけをデプロイ
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_REPO_DIR="/home/isucon/isucon2026"
REMOTE_WEBAPP_DIR="/home/isucon/webapp"
ACCESS_LOG="/var/log/nginx/access.json.log"
DB_HOST="isucon@54.65.131.246"
DB_CONFIG_SOURCE="$SCRIPT_DIR/postgresql/99-query-observability.conf"

get_host() {
  case "$1" in
    asia1) echo "isucon@57.181.195.208" ;;
    europe1) echo "isucon@35.74.6.16" ;;
    america1) echo "isucon@35.74.122.15" ;;
    *) return 1 ;;
  esac
}

SSH_OPTS="-o StrictHostKeyChecking=no"

deploy_db_config() {
  echo ""
  echo "========================================="
  echo "==> Deploying PostgreSQL config to asia2 ($DB_HOST) ..."
  echo "========================================="

  if [ ! -f "$DB_CONFIG_SOURCE" ]; then
    echo "ERROR: PostgreSQL config not found: $DB_CONFIG_SOURCE" >&2
    exit 1
  fi

  DB_PG_CONFIG_FILE=$(ssh $SSH_OPTS "$DB_HOST" \
    "sudo -u postgres psql -XAt -d postgres -c 'SHOW config_file'")
  DB_CLUSTER_INFO=$(ssh $SSH_OPTS "$DB_HOST" \
    "pg_lsclusters --no-header | awk '\$3 == 5432 && \$4 == \"online\" { print \$1, \$2; exit }'")
  if [ -z "$DB_PG_CONFIG_FILE" ] || [ -z "$DB_CLUSTER_INFO" ]; then
    echo "ERROR: could not find the active PostgreSQL cluster on asia2." >&2
    exit 1
  fi
  read -r DB_PG_VERSION DB_CLUSTER <<EOF
$DB_CLUSTER_INFO
EOF
  DB_CONFIG_DIR="$(dirname "$DB_PG_CONFIG_FILE")/conf.d"

  ssh $SSH_OPTS "$DB_HOST" \
    "sudo install -d -o root -g postgres -m 0755 '$DB_CONFIG_DIR'"

  DB_CONFIG_CHANGES=$(rsync -azi --no-owner --no-group \
    --out-format='%i %n' \
    --rsync-path="sudo -n rsync" \
    -e "ssh $SSH_OPTS" \
    "$DB_CONFIG_SOURCE" \
    "$DB_HOST:$DB_CONFIG_DIR/99-query-observability.conf")

  if [ -n "$DB_CONFIG_CHANGES" ]; then
    echo "$DB_CONFIG_CHANGES"
    echo "--> Reloading PostgreSQL configuration ..."
    ssh $SSH_OPTS "$DB_HOST" \
      "sudo pg_ctlcluster '$DB_PG_VERSION' '$DB_CLUSTER' reload"
  else
    echo "--> PostgreSQL config unchanged."
  fi
}

# 引数でアプリサーバーを絞り込める。DB 設定は毎回同期し、db/asia2 のみなら DB 設定だけを反映する。
if [ $# -ge 1 ]; then
  TARGET_NAMES=()
  APP_TARGET_SELECTED=0
  for TARGET_NAME in "$@"; do
    case "$TARGET_NAME" in
      db|asia2)
        ;;
      asia1|europe1|america1)
        TARGET_NAMES+=("$TARGET_NAME")
        APP_TARGET_SELECTED=1
        ;;
      *)
        echo "ERROR: Unknown server name '$TARGET_NAME'. Valid: asia1, europe1, america1, db, asia2" >&2
        exit 1
        ;;
    esac
  done
else
  TARGET_NAMES=("asia1" "europe1" "america1")
  APP_TARGET_SELECTED=1
fi

deploy_db_config
if [ "$APP_TARGET_SELECTED" -eq 0 ]; then
  echo "DB config deployment finished."
  exit 0
fi

for NAME in "${TARGET_NAMES[@]}"; do
  if ! HOST="$(get_host "$NAME")"; then
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

  # nginx のアクセスログ設定を /etc/nginx/conf.d に配置
  echo "--> rsync nginx config ..."
  rsync -az \
    --no-owner \
    --no-group \
    --rsync-path="sudo -n rsync" \
    -e "ssh $SSH_OPTS" \
    "$SCRIPT_DIR/../conf/nginx/alp-log.conf" \
    "$HOST:/etc/nginx/conf.d/alp-log.conf"

  ssh $SSH_OPTS "$HOST" "
    set -eu

    # nginx 設定を検証して反映
    echo '--> Testing and reloading nginx ...'
    sudo chmod 0644 /etc/nginx/conf.d/alp-log.conf
    sudo nginx -t
    sudo systemctl reload nginx.service

    # アクセスログをリセットし、ログ収集用の所有者・グループに設定
    sudo truncate -s 0 '$ACCESS_LOG' && sudo chown syslog:adm '$ACCESS_LOG'

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

    # 4. nginx 設定を反映 (アプリが X-Accel-Redirect を返すので必ず再起動より先に)
    echo '--> Applying nginx config ...'
    mkdir -p /home/isucon/image-cache
    sudo install -m 644 '$REMOTE_REPO_DIR/provisioning/nginx/nginx.conf' /etc/nginx/nginx.conf
    sudo install -m 644 '$REMOTE_REPO_DIR/provisioning/nginx/sites-available/isureal.conf' /etc/nginx/sites-available/isureal.conf
    sudo install -m 644 '$REMOTE_REPO_DIR/provisioning/nginx/conf.d/alp-log.conf' /etc/nginx/conf.d/alp-log.conf
    sudo nginx -t -q
    sudo systemctl reload nginx.service

    # 5. サービス再起動
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

FAILED_HOSTS=""
for NAME in "${TARGET_NAMES[@]}"; do
  HOST="$(get_host "$NAME")"
  echo ""
  echo "--> Checking $NAME ($HOST) ..."

  # isureal-go.service の状態確認
  SVC_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active isureal-go.service" 2>/dev/null || echo "unknown")
  if [ "$SVC_STATUS" != "active" ]; then
    echo "    [FAIL] isureal-go.service is '$SVC_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u isureal-go.service -n 50 --no-pager'"
    FAILED_HOSTS="${FAILED_HOSTS:+$FAILED_HOSTS }$NAME"
    continue
  fi
  echo "    [OK]   isureal-go.service is active"

  # nginx.service の状態確認
  NGX_STATUS=$(ssh $SSH_OPTS "$HOST" "systemctl is-active nginx.service" 2>/dev/null || echo "unknown")
  if [ "$NGX_STATUS" != "active" ]; then
    echo "    [FAIL] nginx.service is '$NGX_STATUS'"
    echo "           Fix: ssh $HOST 'journalctl -u nginx.service -n 20 --no-pager'"
    FAILED_HOSTS="${FAILED_HOSTS:+$FAILED_HOSTS }$NAME"
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
      FAILED_HOSTS="${FAILED_HOSTS:+$FAILED_HOSTS }$NAME"
      continue
      ;;
    *)
      echo "    [WARN] HTTP $HTTP_STATUS from localhost (may be OK)"
      ;;
  esac
done

echo ""
echo "========================================="
if [ -n "$FAILED_HOSTS" ]; then
  echo "[FAIL] Health check failed on: $FAILED_HOSTS"
  echo ""
  echo "Troubleshooting:"
  for NAME in $FAILED_HOSTS; do
    H="$(get_host "$NAME")"
    echo "  ssh $H 'journalctl -u isureal-go.service -n 50 --no-pager'"
  done
  echo "========================================="
  exit 1
else
  echo "[OK] All health checks passed!"
  echo "========================================="
fi
