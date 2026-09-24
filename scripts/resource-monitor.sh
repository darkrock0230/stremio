#!/bin/bash
# Autonomous Resource & Health Monitor
# Preemptively prevents OOM crashes by monitoring memory pressure and system health.

STREMIO_DIR="/home/runner/stremio"
LOG_FILE="${STREMIO_DIR}/stremio.log"
RECYCLE_SCRIPT="${STREMIO_DIR}/recycle-service.sh"

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [MONITOR] $1" >> "$LOG_FILE"
}

# Signal trap for clean termination
cleanup() {
  log "Termination signal caught. Resource monitor shutting down."
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
CRIT_FREE_MB=1200
if [ -n "$TOTAL_MEM" ] && [ "$TOTAL_MEM" -lt 6000 ]; then
  CRIT_FREE_MB=600
fi

log "Resource monitor active. Host RAM: ${TOTAL_MEM}MB. Buffer Threshold: ${CRIT_FREE_MB}MB free."

CONSECUTIVE_UNHEALTHY=0

while true; do
  sleep $((8 + RANDOM % 5))

  AVAIL_MEM=$(free -m | awk '/^Mem:/{print $7}')
  SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')

  # Check 1: Critically low available system memory
  if [ -n "$AVAIL_MEM" ] && [ "$AVAIL_MEM" -lt "$CRIT_FREE_MB" ]; then
    log "CRITICAL: Available RAM low (${AVAIL_MEM}MB < ${CRIT_FREE_MB}MB, swap: ${SWAP_USED}MB). Averting OOM..."
    if [ -x "$RECYCLE_SCRIPT" ]; then
      "$RECYCLE_SCRIPT" "MEMORY_PRESSURE (${AVAIL_MEM}MB free)"
    fi
    sleep 15
    continue
  fi

  # Check 2: Node RSS memory limit
  NODE_PIDS=$(pgrep -f "node server.js" || true)
  if [ -n "$NODE_PIDS" ]; then
    for PID in $NODE_PIDS; do
      RSS_KB=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null || echo 0)
      RSS_MB=$((RSS_KB / 1024))
      MAX_NODE_MB=$((TOTAL_MEM * 75 / 100))

      if [ "$RSS_MB" -gt "$MAX_NODE_MB" ]; then
        log "CRITICAL: Service PID $PID RSS bloated (${RSS_MB}MB > ${MAX_NODE_MB}MB limit). Recycling instance..."
        if [ -x "$RECYCLE_SCRIPT" ]; then
          "$RECYCLE_SCRIPT" "RSS_PRESSURE (${RSS_MB}MB)"
        fi
        sleep 15
        break
      fi
    done
  fi

  # Check 3: HTTP responsiveness check
  if pgrep -f "node server.js" > /dev/null; then
    if ! curl -s --max-time 4 "http://127.0.0.1:11470/stats.json" > /dev/null; then
      CONSECUTIVE_UNHEALTHY=$((CONSECUTIVE_UNHEALTHY + 1))
      if [ "$CONSECUTIVE_UNHEALTHY" -ge 3 ]; then
        log "WARNING: Service unresponsive for 3 consecutive checks (30s). Re-initializing..."
        if [ -x "$RECYCLE_SCRIPT" ]; then
          "$RECYCLE_SCRIPT" "SERVICE_UNRESPONSIVE"
        fi
        CONSECUTIVE_UNHEALTHY=0
        sleep 10
      fi
    else
      CONSECUTIVE_UNHEALTHY=0
    fi
  fi
done
