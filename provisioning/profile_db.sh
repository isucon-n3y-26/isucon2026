#!/usr/bin/env bash
# asia2 の pg_stat_statements から、ISUCON の SQL 改善に使う統計を表示する。
# 使い方: bash provisioning/profile_db.sh

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

DB_HOST="isucon@54.65.131.246"
SSH_OPTS=(-o StrictHostKeyChecking=no)

ssh "${SSH_OPTS[@]}" "$DB_HOST" \
  "sudo -u postgres psql -X -P pager=off -d postgres" <<'SQL'
\echo '統計のリセット時刻（この時刻以降の累積値）:'
SELECT stats_reset FROM pg_stat_statements_info;

\echo ''
\echo 'SQL別の累積実行時間 上位20件:'
SELECT d.datname AS db,
       s.calls,
       round(s.total_exec_time::numeric, 1) AS total_ms,
       round(s.mean_exec_time::numeric, 2) AS avg_ms,
       round(s.max_exec_time::numeric, 2) AS max_ms,
       s.rows,
       s.shared_blks_read AS read_blocks,
       s.temp_blks_written AS temp_write_blocks,
       regexp_replace(s.query, '[[:space:]]+', ' ', 'g') AS query
FROM pg_stat_statements AS s
JOIN pg_database AS d ON d.oid = s.dbid
WHERE NOT d.datistemplate
  AND d.datname <> 'postgres'
ORDER BY s.total_exec_time DESC
LIMIT 20;
SQL
