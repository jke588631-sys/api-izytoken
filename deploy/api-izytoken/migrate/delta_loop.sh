#!/bin/bash
# 用法: PG_PASS 从 /opt/new-api-migrated/.env 的 POSTGRES_PASSWORD 读取，勿硬编码
PG_PASS=$(grep -E "^POSTGRES_PASSWORD=" /opt/new-api-migrated/.env | cut -d= -f2-)
[ -z "$PG_PASS" ] && { echo "PG_PASS 未取到，检查 .env"; exit 1; }# 每10分钟把 live SQLite 新数据同步到 PG，直至正式切换
while true; do
  ts=$(date '+%F %T')
  echo "=== delta loop $ts ===" >> /opt/new-api-migrated/migrate/delta_loop.log
  cd /opt/new-api-migrated/migrate
  OUT=$(PG_PASS="$PG_PASS" python3 /opt/new-api-migrated/migrate/sqlite_to_pg.py delta /opt/new-api-migrated/data/one-api.db /opt/new-api-migrated/migrate/t0_max.txt 2>&1)
  echo "$OUT" >> /opt/new-api-migrated/migrate/delta_loop.log
  # 提取关键信息写到状态文件
  ROWS=$(echo "$OUT" | grep -oE 'logs delta rows: [0-9]+' | awk '{print $NF}')
  NEWMAX=$(echo "$OUT" | grep -oE 'new T0_max = [0-9]+' | awk '{print $NF}')
  PGROWS=$(docker exec new-api-migrated-postgres psql -U root -d new-api -tc "SELECT count(*) FROM logs;" 2>/dev/null | tr -d ' ')
  echo "last_sync_time=$ts" > /opt/new-api-migrated/migrate/delta_status.txt
  echo "delta_rows=${ROWS:-0}" >> /opt/new-api-migrated/migrate/delta_status.txt
  echo "t0_max=${NEWMAX:-?}" >> /opt/new-api-migrated/migrate/delta_status.txt
  echo "pg_logs_total=${PGROWS:-?}" >> /opt/new-api-migrated/migrate/delta_status.txt
  echo "sleeping 600s" >> /opt/new-api-migrated/migrate/delta_loop.log
  sleep 600
done
