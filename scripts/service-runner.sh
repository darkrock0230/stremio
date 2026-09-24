#!/bin/bash
# Process Supervisor & Lifecycle Runner
# Ensures background services run stably, prevents crash loops, and handles clean teardown.

STREMIO_DIR="/home/runner/stremio"
LOG_FILE="${STREMIO_DIR}/stremio.log"
mkdir -p "$STREMIO_DIR"
cd "$STREMIO_DIR" || exit 1

# Dynamically calculate safe Node heap (reserves at least 3.5 GB for OS + Docker + runner)
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
if [ -n "$TOTAL_MEM" ] && [ "$TOTAL_MEM" -gt 10000 ]; then
  NODE_HEAP=9216
elif [ -n "$TOTAL_MEM" ] && [ "$TOTAL_MEM" -gt 6000 ]; then
  NODE_HEAP=4608
else
  NODE_HEAP=2048
fi

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [SUPERVISOR] $1" >> "$LOG_FILE"
}

# Signal trap for clean workflow termination
SHUTDOWN=0
cleanup() {
  SHUTDOWN=1
  log "Termination signal caught. Stopping service gracefully..."
  pkill -15 -P $$ 2>/dev/null || true
  pkill -15 -f "node server.js" 2>/dev/null || true
  sleep 1
  pkill -9 -P $$ 2>/dev/null || true
  pkill -9 -f "node server.js" 2>/dev/null || true
  log "Supervisor shut down cleanly."
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

log "Service runner initialized. Total RAM: ${TOTAL_MEM}MB. Node Heap: ${NODE_HEAP}MB."

while [ "$SHUTDOWN" -eq 0 ]; do
  if ! pgrep -f "node server.js" > /dev/null; then
    log "Launching clean service instance..."

    env NO_CORS=1 NODE_OPTIONS="--max-old-space-size=${NODE_HEAP}" node server.js >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "${STREMIO_DIR}/server.pid"

    log "Service started with PID ${SERVER_PID}."
    wait "$SERVER_PID" 2>/dev/null
    EXIT_CODE=$?

    if [ "$SHUTDOWN" -eq 1 ]; then
      break
    fi

    log "Service exited with status ${EXIT_CODE}."

    # Cooldown and memory cleanup before next respawn
    rm -rf /tmp/torrent-stream* /tmp/stremio* 2>/dev/null || true
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 3
  else
    sleep 5
  fi
done
