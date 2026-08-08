#!/bin/bash
# 每天清理 PG 中超过 30 天的 logs（分批，避免长时间锁表影响生产）
# created_at 是 unix 整数（bigint）
cutoff=$(date -d '-30 days' +%s)
DELETED=0
while :; do
  BATCH=$(docker exec new-api-migrated-postgres psql -U root -d new-api -Atc "DELETE FROM logs WHERE created_at < $cutoff RETURNING id" 2>/dev/null | wc -l)
  if [ "$BATCH" -le 1 ]; then
    break
  fi
  DELETED=$((DELETED + BATCH - 1))
  sleep 2
done
echo "$(date '+%F %T') cleanup: deleted ~$DELETED logs older than 30d (cutoff=$cutoff)"
