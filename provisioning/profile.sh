#!/usr/bin/env bash
# 3台のアプリサーバーのnginxアクセスログをalpで集計する。
# 使い方: bash provisioning/profile.sh

set -u

SSH_OPTS=(-o StrictHostKeyChecking=no)

APP_HOSTS=(
  "asia1:isucon@57.181.195.208"
  "europe1:isucon@35.74.6.16"
  "america1:isucon@35.74.122.15"
)

FAILED_HOSTS=""

for TARGET in "${APP_HOSTS[@]}"; do
  NAME="${TARGET%%:*}"
  HOST="${TARGET#*:}"

  echo
  echo "========================================="
  echo "==> alp profile: ${NAME} (${HOST})"
  echo "========================================="

  if ! ssh "${SSH_OPTS[@]}" "$HOST" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

ACCESS_LOG="/var/log/nginx/access.json.log"
ALP_BIN="/usr/local/bin/alp"
MATCHING_GROUPS='/api/posts/[^/]+/comments,/api/posts/[^/]+/realmojis,/api/friend-requests/[^/]+/accept,/api/friend-requests/[^/]+/reject,/api/friend-requests/[^/]+/cancel,/api/admin/users/[^/]+/certification,/api/memories/[0-9]{4}-[0-9]{2}-[0-9]{2},/api/images/[^/]+,/api/users/[^/]+,/api/posts/[^/]+$,/api/comments/[^/]+,/api/realmojis/[^/]+,/api/friendships/[^/]+,/api/follows/[^/]+,/api/blocks/[^/]+'

sudo cat "${ACCESS_LOG}" | "${ALP_BIN}" json --sort avg --output count,method,uri,min,max,sum,avg,p99 --format md -m "${MATCHING_GROUPS}"
REMOTE_SCRIPT
  then
    echo "[FAIL] alp profiling failed on ${NAME}" >&2
    FAILED_HOSTS="${FAILED_HOSTS:+$FAILED_HOSTS }$NAME"
  fi
done

if [ -n "$FAILED_HOSTS" ]; then
  echo "[FAIL] Profiling failed on: $FAILED_HOSTS" >&2
  exit 1
fi
