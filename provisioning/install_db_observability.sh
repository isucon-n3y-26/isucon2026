#!/usr/bin/env bash
# asia2 に pgBadger と pg_stat_statements を導入し、PostgreSQL の遅い SQL ログを設定する。
# shared_preload_libraries の変更が必要な場合、PostgreSQL クラスタを再起動する。
# 使い方: bash provisioning/install_db_observability.sh

set -euo pipefail

DB_HOST="isucon@54.65.131.246"
SSH_OPTS=(-o StrictHostKeyChecking=no)

if ! ssh "${SSH_OPTS[@]}" "$DB_HOST" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: this installer expects an Ubuntu/Debian DB server with apt-get." >&2
  exit 1
fi
if ! command -v psql >/dev/null 2>&1 || ! command -v pg_lsclusters >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL client and pg_lsclusters must be installed first." >&2
  exit 1
fi

PG_VERSION="$(sudo -u postgres psql -XAt -d postgres -c 'SHOW server_version' | cut -d. -f1)"
if [[ ! "$PG_VERSION" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not determine PostgreSQL major version." >&2
  exit 1
fi

CLUSTER="$(pg_lsclusters --no-header | awk -v version="$PG_VERSION" '$1 == version && $3 == 5432 && $4 == "online" { print $2; exit }')"
if [[ -z "$CLUSTER" ]]; then
  echo "ERROR: no online PostgreSQL $PG_VERSION cluster found on port 5432." >&2
  exit 1
fi

echo "==> Installing pgBadger and PostgreSQL $PG_VERSION contrib extensions ..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends pgbadger "postgresql-contrib-$PG_VERSION"

if ! sudo -u postgres psql -XAt -d postgres -c \
  "SELECT name FROM pg_available_extensions WHERE name = 'pg_stat_statements'" | grep -qx pg_stat_statements; then
  echo "ERROR: pg_stat_statements is not available after package installation." >&2
  exit 1
fi

PG_CONFIG_FILE="$(sudo -u postgres psql -XAt -d postgres -c 'SHOW config_file')"
if ! sudo grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$PG_CONFIG_FILE"; then
  echo "ERROR: $PG_CONFIG_FILE does not include the Debian-style conf.d directory." >&2
  exit 1
fi

CONFIG_DIR="$(dirname "$PG_CONFIG_FILE")/conf.d"
CONFIG_DEST="$CONFIG_DIR/99-query-observability.conf"
if [[ ! -f "$CONFIG_DEST" ]]; then
  echo "ERROR: PostgreSQL config has not been deployed to $CONFIG_DEST." >&2
  echo "Run 'bash provisioning/deploy.sh db' first." >&2
  exit 1
fi

# Preserve any libraries already configured on the server while adding pg_stat_statements.
CURRENT_PRELOAD="$(sudo -u postgres psql -XAt -d postgres -c 'SHOW shared_preload_libraries')"
PRELOAD_LIBRARIES="$(printf '%s\n' "$CURRENT_PRELOAD" | awk -F, '
  {
    for (i = 1; i <= NF; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      if ($i != "" && !seen[$i]++) {
        if (out != "") out = out ","
        out = out $i
      }
    }
  }
  END {
    if (!seen["pg_stat_statements"]) {
      if (out != "") out = out ","
      out = out "pg_stat_statements"
    }
    print out
  }
')"

RESTART_REQUIRED=0
if ! printf '%s\n' "$CURRENT_PRELOAD" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq pg_stat_statements; then
  sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres --set=preload="$PRELOAD_LIBRARIES" <<'SQL'
ALTER SYSTEM SET shared_preload_libraries = :'preload';
SQL
  RESTART_REQUIRED=1
fi

if [[ "$RESTART_REQUIRED" -eq 1 ]]; then
  echo "==> Restarting PostgreSQL $PG_VERSION/$CLUSTER to load pg_stat_statements ..."
  sudo pg_ctlcluster "$PG_VERSION" "$CLUSTER" restart
fi

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'

echo "==> Verifying installation ..."
pgbadger --version
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres -c \
  "SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements'"
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres -c \
  "SELECT name, setting, unit FROM pg_settings WHERE name IN ('log_min_duration_statement', 'log_parameter_max_length') ORDER BY name"

echo "pgBadger and PostgreSQL query statistics are ready on asia2."
REMOTE_SCRIPT
then
  echo "ERROR: DB observability setup failed on $DB_HOST." >&2
  exit 1
fi

echo "asia2: pgBadger and pg_stat_statements installed."
