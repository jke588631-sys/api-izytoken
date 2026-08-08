#!/bin/bash
# new-api 中转站监控 —— 只读，不修改任何生产配置
# 由 systemd timer 每 5 分钟触发。详见 /opt/new-api-migrated/PROGRESS.md 2026-08-05
set -uo pipefail

CONTAINER=new-api-migrated
CONF=/etc/new-api-monitor.conf
STATE_DIR=/var/lib/new-api-monitor
STATE=$STATE_DIR/state
LOG=/var/log/new-api-monitor.log

# ---- 阈值（可在 CONF 里覆盖）----
WARN_ANON_GB=8          # 早期预警：内存爬到此值。历史上 07-28 到 10.8GB，距 07-31 宕机还有 3 天
CRIT_ANON_GB=13         # 危急：逼近 16GB 硬上限
WARN_TIMEOUT_DELTA=200  # 5 分钟内上游超时新增条数超过此值
RENOTIFY_HOURS=6        # 同一问题持续存在时，每 N 小时重复提醒一次

mkdir -p "$STATE_DIR"
touch "$STATE"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

now=$(date '+%Y-%m-%d %H:%M:%S')
now_ts=$(date +%s)

log() { echo "[$now] $*" >> "$LOG"; }

get_state() { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_state() {
  local k=$1 v=$2 tmp
  tmp=$(mktemp)
  grep -v "^$k=" "$STATE" 2>/dev/null > "$tmp"
  echo "$k=$v" >> "$tmp"
  mv "$tmp" "$STATE"
}

# ---- 通知发送 ----
send_notify() {
  local level=$1 title=$2 body=$3
  local text="【$level】$title
$body

服务器: $(hostname) / 43.225.196.34
时间: $now"

  log "NOTIFY[$level] $title | $body"

  local sent=0
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -m 15 -o /dev/null -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode text="$text" && sent=1
  fi
  if [ -n "${WECOM_WEBHOOK:-}" ]; then
    curl -s -m 15 -o /dev/null -X POST "$WECOM_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"msgtype":"text","text":{"content":sys.stdin.read()}}))' <<<"$text")" && sent=1
  fi
  if [ -n "${FEISHU_WEBHOOK:-}" ]; then
    curl -s -m 15 -o /dev/null -X POST "$FEISHU_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"msg_type":"text","content":{"text":sys.stdin.read()}}))' <<<"$text")" && sent=1
  fi
  [ "$sent" = 0 ] && log "  (未配置通知渠道，仅写入本地日志 $LOG)"
  return 0
}

# 带去重与冷却的告警
alert() {
  local key=$1 level=$2 title=$3 body=$4
  local last_lvl last_ts
  last_lvl=$(get_state "lvl_$key")
  last_ts=$(get_state "ts_$key")
  last_ts=${last_ts:-0}
  if [ "$last_lvl" != "$level" ] || [ $(( now_ts - last_ts )) -ge $(( RENOTIFY_HOURS * 3600 )) ]; then
    send_notify "$level" "$title" "$body"
    set_state "ts_$key" "$now_ts"
  fi
  set_state "lvl_$key" "$level"
}

# 恢复通知
recover() {
  local key=$1 title=$2
  local last_lvl
  last_lvl=$(get_state "lvl_$key")
  if [ -n "$last_lvl" ] && [ "$last_lvl" != "OK" ]; then
    send_notify "恢复" "$title" "指标已回到正常范围"
    set_state "ts_$key" "$now_ts"
  fi
  set_state "lvl_$key" "OK"
}

########## 检查 1：容器是否在运行 ##########
status=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null)
if [ -z "$status" ]; then
  alert container CRIT "new-api 容器不存在" "docker inspect 查不到 $CONTAINER"
  exit 0
fi
if [ "$status" != "running" ]; then
  alert container CRIT "new-api 容器未运行" "当前状态: $status"
  exit 0
fi
recover container "new-api 容器"

########## 检查 2：保险丝是否跳过（RestartCount / OOMKilled）##########
restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}')
oomkilled=$(docker inspect "$CONTAINER" --format '{{.State.OOMKilled}}')
last_restarts=$(get_state restarts)
last_restarts=${last_restarts:-$restarts}

if [ "$restarts" -gt "$last_restarts" ]; then
  send_notify "CRIT" "new-api 容器发生重启（内存保险丝可能已触发）" \
    "RestartCount: $last_restarts -> $restarts
OOMKilled: $oomkilled
说明: 已配置 16GB 硬上限，超限会被 OOM-kill 并自动拉起。
这通常意味着上游挂死导致请求积压。请检查上游 43.225.196.206:3000 与通道 40。"
fi
set_state restarts "$restarts"

if [ "$oomkilled" = "true" ]; then
  alert oom CRIT "new-api 被 OOM-kill" "确认为内存超限导致。请排查上游与在飞请求积压。"
else
  recover oom "new-api OOM 状态"
fi

########## 检查 3：内存水位（核心早期预警）##########
cid=$(docker inspect "$CONTAINER" --format '{{.Id}}')
CG=/sys/fs/cgroup/system.slice/docker-$cid.scope
anon_b=$(grep '^anon ' "$CG/memory.stat" 2>/dev/null | awk '{print $2}')
max_b=$(cat "$CG/memory.max" 2>/dev/null)

if [ -n "${anon_b:-}" ]; then
  anon_gb=$(awk -v b="$anon_b" 'BEGIN{printf "%.2f", b/1073741824}')
  if [ "$max_b" = "max" ]; then max_gb="无上限"; else
    max_gb=$(awk -v b="$max_b" 'BEGIN{printf "%.0f", b/1073741824}')
  fi
  over_crit=$(awk -v a="$anon_gb" -v t="$CRIT_ANON_GB" 'BEGIN{print (a>=t)?1:0}')
  over_warn=$(awk -v a="$anon_gb" -v t="$WARN_ANON_GB" 'BEGIN{print (a>=t)?1:0}')

  if [ "$over_crit" = 1 ]; then
    alert mem CRIT "new-api 内存危急 ${anon_gb}GB" \
      "真实占用(anon) ${anon_gb}GB / 上限 ${max_gb}GB，即将触发 OOM-kill。
建议立即检查上游是否挂死；必要时重启容器主动泄压（约 10 秒中断）。"
  elif [ "$over_warn" = 1 ]; then
    alert mem WARN "new-api 内存偏高 ${anon_gb}GB" \
      "真实占用(anon) ${anon_gb}GB / 上限 ${max_gb}GB，已超过预警线 ${WARN_ANON_GB}GB。
历史参考: 07-28 到 10.8GB，3 天后(07-31)涨到 23GB 导致整机宕机。
现在处理还有充足时间。请检查上游 43.225.196.206:3000 的响应情况。"
  else
    recover mem "new-api 内存水位"
  fi
  set_state anon_gb "$anon_gb"
fi

########## 检查 4：服务健康 ##########
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3001/api/status 2>/dev/null)
if [ "$code" != "200" ]; then
  alert health CRIT "new-api 健康检查失败" "GET /api/status 返回 HTTP ${code:-无响应}"
else
  recover health "new-api 健康检查"
fi

########## 检查 5：上游超时激增（最早期的因）##########
newest=$(ls -t /opt/new-api-migrated/data/logs/oneapi-*.log 2>/dev/null | head -1)
if [ -n "${newest:-}" ]; then
  cur_cnt=$(LC_ALL=C grep -c "context deadline exceeded" "$newest" 2>/dev/null || echo 0)
  last_file=$(get_state to_file)
  last_cnt=$(get_state to_cnt)
  if [ "$last_file" = "$newest" ] && [ -n "${last_cnt:-}" ]; then
    delta=$(( cur_cnt - last_cnt ))
    [ "$delta" -lt 0 ] && delta=0
    if [ "$delta" -ge "$WARN_TIMEOUT_DELTA" ]; then
      alert upstream WARN "上游超时激增 (5分钟内 +$delta 条)" \
        "日志文件: $(basename "$newest")
这是内存飙升的先行指标——上游挂死导致请求积压，内存随后上涨。
请检查上游 43.225.196.206:3000（通道 40）。"
    else
      recover upstream "上游超时率"
    fi
  fi
  set_state to_file "$newest"
  set_state to_cnt "$cur_cnt"
fi

########## 每次都记一行状态，便于回溯 ##########
log "OK check: status=$status restarts=$restarts oom=$oomkilled anon=${anon_gb:-?}GB health=$code timeouts=${cur_cnt:-?}"
exit 0
