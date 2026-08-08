#!/bin/bash
# 分批删除: 30天前所有日志 + 全部type=5错误日志
DB=/opt/new-api-migrated/data/one-api.db
CUT=1782650522
BATCH=5000
LOG=/opt/new-api-migrated/purge_logs.progress
TOTAL_DEL=0
echo "=== START $(date "+%F %T") ===" >> $LOG
while true; do
  OUT=$(sqlite3 -cmd ".timeout 60000" "$DB" "PRAGMA busy_timeout=60000; DELETE FROM logs WHERE rowid IN (SELECT rowid FROM logs WHERE created_at < $CUT OR type=5 LIMIT $BATCH); SELECT changes();" 2>&1)
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "$(date "+%F %T") ERROR rc=$RC out=$OUT" >> $LOG
    sleep 5
    continue
  fi
  N=$(echo "$OUT" | tail -1)
  case "$N" in (*[!0-9]*|"") echo "$(date "+%F %T") BADOUT=$OUT" >> $LOG; sleep 5; continue ;; esac
  TOTAL_DEL=$((TOTAL_DEL + N))
  if [ "$N" -eq 0 ]; then
    echo "$(date "+%F %T") DONE total_deleted=$TOTAL_DEL" >> $LOG
    break
  fi
  if [ $((TOTAL_DEL % 100000)) -lt $BATCH ]; then
    WAL=$(stat -c %s "$DB-wal" 2>/dev/null || echo 0)
    echo "$(date "+%F %T") deleted=$TOTAL_DEL wal=$WAL" >> $LOG
  fi
  sleep 0.3
done
echo "=== END $(date "+%F %T") deleted=$TOTAL_DEL ===" >> $LOG
