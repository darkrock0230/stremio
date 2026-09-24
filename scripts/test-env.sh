#!/bin/bash
set -e

echo "============================================"
echo "  Initializing test environment"
echo "============================================"

# Install runtime dependencies (only ffmpeg is missing; node, npm, curl, wget, jq are already present)
export DEBIAN_FRONTEND=noninteractive
sudo rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/chrome.list 2>/dev/null || true
sudo apt-get update -o Acquire::Retries=3 -qq || true
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Installing ffmpeg..."
  sudo apt-get install -y --no-install-recommends ffmpeg 2>/dev/null || (sleep 2 && sudo apt-get install -y --no-install-recommends ffmpeg) || true
fi

# Configure streaming engine for E2E tests
echo "Setting up streaming engine..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /home/runner/stremio
cd /home/runner/stremio
echo "Resolving latest engine version..."

# Resolve the latest available server version with solid fallback
DEFAULT_SERVER="https://dl.strem.io/server/v4.20.16/desktop/server.js"
BASELINE_URL=$(curl -s --connect-timeout 5 https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt || true)
BASE_MINOR=$(echo "$BASELINE_URL" | grep -oP 'v4\.\K[0-9]+' || echo "20")

CEILING=$((BASE_MINOR + 5))
LATEST_SERVER=""

for (( MINOR=CEILING; MINOR>=BASE_MINOR; MINOR-- )); do
  for PATCH in {6..0}; do
    URL="https://dl.strem.io/server/v4.${MINOR}.${PATCH}/desktop/server.js"
    if curl --output /dev/null --silent --head --fail --connect-timeout 2 --max-time 3 "$URL"; then
      LATEST_SERVER="$URL"
      echo "  Resolved: v4.${MINOR}.${PATCH}"
      break 2
    fi
  done
done

if [ -z "$LATEST_SERVER" ]; then
  LATEST_SERVER="${BASELINE_URL:-$DEFAULT_SERVER}"
  echo "  Using baseline version: $LATEST_SERVER"
fi

wget -qO server.js "$LATEST_SERVER" || wget -qO server.js "$DEFAULT_SERVER" || true
if [ ! -s server.js ]; then
  echo "Warning: Retrying server.js download with curl..."
  curl -fsSL -o server.js "$DEFAULT_SERVER" || true
fi

echo "Configuring engine endpoints..."
sed -i -E 's/enginefs\.baseUrl\s*=\s*.*/enginefs.baseUrl = "https:\/\/stremio.avkstream.qzz.io";/g' server.js

echo "Tuning engine parameters..."
sed -i -E 's/STREAM_TIMEOUT\s*=\s*[0-9eE.]*/STREAM_TIMEOUT = 20000/g' server.js
sed -i -E 's/ENGINE_TIMEOUT\s*=\s*[0-9eE.]*/ENGINE_TIMEOUT = 20000/g' server.js

echo "Configuring runtime settings..."
mkdir -p ~/.stremio-server
echo '{"cacheSize": 10737418240, "btMaxConnections": 1000, "btHandshakeTimeout": 5000, "btRequestTimeout": 2000, "btConnectionTimeout": 2000, "btDownloadSpeedSoftLimit": 0, "btDownloadSpeedHardLimit": 0, "btMinPeersForStable": 10}' > ~/.stremio-server/server-settings.json

echo "Installing lifecycle and monitoring scripts..."
cp "$SCRIPT_DIR/service-runner.sh" /home/runner/stremio/
cp "$SCRIPT_DIR/recycle-service.sh" /home/runner/stremio/
cp "$SCRIPT_DIR/resource-monitor.sh" /home/runner/stremio/
chmod +x /home/runner/stremio/*.sh

echo "Cleaning up stale processes..."
pkill -f "service-runner.sh" 2>/dev/null || true
pkill -f "resource-monitor.sh" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
pkill -f "log_server.js" 2>/dev/null || true

echo "Starting service runner and resource monitor..."
nohup /home/runner/stremio/service-runner.sh > /dev/null 2>&1 &
nohup /home/runner/stremio/resource-monitor.sh > /dev/null 2>&1 &
sleep 5

# Start media proxy service
echo "Starting media proxy..."
docker rm -f mediaflow 2>/dev/null || true
docker run -d --restart always --name mediaflow -p 8888:8888 -e API_PASSWORD="${MEDIAFLOW_PASS}" mhdzumair/mediaflow-proxy:latest || true

# Start monitoring agent
echo "Starting monitoring agent..."
mkdir -p /home/runner/beszel_agent_data
echo "f4c9c1b9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1" > /home/runner/beszel_agent_data/fingerprint
docker rm -f beszel-agent 2>/dev/null || true
docker run -d --restart always --name beszel-agent --network host -v /var/run/docker.sock:/var/run/docker.sock:ro -v /home/runner/beszel_agent_data:/var/lib/beszel-agent -e LISTEN=45876 -e KEY="${BESZEL_KEY}" -e TOKEN="${BESZEL_TOKEN}" -e HUB_URL="https://beszel-latest-wimr.onrender.com" henrygd/beszel-agent || true

# Start log endpoint
echo "Starting log endpoint..."
cat << 'EOF' > /home/runner/log_server.js
const http = require('http');
const fs = require('fs');
const url = require('url');

const expectedPass = process.env.MEDIAFLOW_PASS;

const server = http.createServer((req, res) => {
    const query = url.parse(req.url, true).query;
    if (query.pass !== expectedPass) {
        res.writeHead(401, { 'Content-Type': 'text/plain' });
        res.end('Unauthorized');
        return;
    }
    
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    if (fs.existsSync('/home/runner/stremio/stremio.log')) {
        const stream = fs.createReadStream('/home/runner/stremio/stremio.log');
        stream.pipe(res);
    } else {
        res.end('Log not available yet.');
    }
});

server.listen(8080, () => {
    console.log('Log endpoint listening on port 8080');
});
EOF
nohup node /home/runner/log_server.js > /home/runner/log_server.log 2>&1 &

# Setup tunnel
echo "Setting up tunnel..."
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL --retry 3 --connect-timeout 10 -o cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb || true
  if [ -f cloudflared.deb ]; then
    sudo dpkg -i cloudflared.deb 2>/dev/null || true
  fi
fi

echo "Starting tunnel service..."
sudo cloudflared service install ${CF_TUNNEL_TOKEN} 2>/dev/null || true
sudo sed -i 's/RestartSec=[0-9]*/RestartSec=100ms/g' /etc/systemd/system/cloudflared*.service 2>/dev/null || true
sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl restart cloudflared 2>/dev/null || \
sudo cloudflared service start 2>/dev/null || \
nohup cloudflared tunnel run --token "${CF_TUNNEL_TOKEN}" > /home/runner/cloudflared.log 2>&1 &

echo "============================================"
echo "  Test environment ready"
echo "  Endpoint: https://stremio.avkstream.qzz.io"
echo "============================================"
