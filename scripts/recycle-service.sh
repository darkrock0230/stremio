#!/bin/bash
# Service Recycler: Destroys bloated/stalled instance, flushes memory, and initiates fresh instance.

REASON="${1:-MANUAL_OR_CRASH}"
STREMIO_DIR="/home/runner/stremio"
LOG_FILE="${STREMIO_DIR}/stremio.log"

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [RECYCLE] $1" >> "$LOG_FILE"
}

log "Self-healing triggered. Reason: ${REASON}"

# 1. Terminate old server instance
log "Step 1: Terminating service instances..."
pkill -15 -f "node server.js" 2>/dev/null || true
sleep 2
pkill -9 -f "node server.js" 2>/dev/null || true

# 2. Purge stale cache and torrent temp files
log "Step 2: Purging disk cache and temp buffers..."
rm -rf /home/runner/.stremio-server/stremio-cache/* 2>/dev/null || true
rm -rf /tmp/torrent-stream* /tmp/stremio* 2>/dev/null || true

# 3. Drop Linux page cache and reclaim RAM
log "Step 3: Dropping Linux page cache & buffers..."
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null || true

RECLAIMED_MEM=$(free -m | awk '/^Mem:/{print $7}')
log "Step 4: Memory reclaimed: ${RECLAIMED_MEM}MB available."

# 4. Verify supervisor is alive to launch fresh instance
if ! pgrep -f "service-runner.sh" > /dev/null; then
  log "Service runner was not active; launching runner..."
  nohup /home/runner/stremio/service-runner.sh >> "$LOG_FILE" 2>&1 &
fi
