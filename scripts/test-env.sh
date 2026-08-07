#!/bin/bash
set -e

echo "============================================"
echo "  Initializing test environment"
echo "============================================"

# Install runtime dependencies
sudo apt-get update
sudo apt-get install -y curl wget jq nodejs npm gnupg2 ffmpeg

# Configure streaming engine for E2E tests
echo "Setting up streaming engine..."
mkdir -p /home/runner/stremio
cd /home/runner/stremio
echo "Resolving latest engine version..."

# Resolve the latest available server version
BASELINE_URL=$(curl -s https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt)
BASE_MINOR=$(echo "$BASELINE_URL" | grep -oP 'v4\.\K[0-9]+' || echo "20")

CEILING=$((BASE_MINOR + 5))
LATEST_SERVER=""

for (( MINOR=CEILING; MINOR>=BASE_MINOR; MINOR-- )); do
  for PATCH in {6..0}; do
    URL="https://dl.strem.io/server/v4.${MINOR}.${PATCH}/desktop/server.js"
    if curl --output /dev/null --silent --head --fail "$URL"; then
      LATEST_SERVER="$URL"
      echo "  Resolved: v4.${MINOR}.${PATCH}"
      break 2
    fi
  done
done

if [ -z "$LATEST_SERVER" ]; then
  LATEST_SERVER="$BASELINE_URL"
  echo "  Using baseline version"
fi

wget -qO server.js "$LATEST_SERVER"

echo "Configuring engine endpoints..."
sed -i "s/enginefs.baseUrl = \"http:\/\/\" + ip.address() + \":\" + server.address().port/enginefs.baseUrl = \"https:\/\/stremio.avkstream.qzz.io\"/g" server.js

echo "Tuning engine parameters..."
sed -i 's/STREAM_TIMEOUT[[:space:]]*=[[:space:]]*[0-9eE.]*/STREAM_TIMEOUT = 1000/g' server.js
sed -i 's/ENGINE_TIMEOUT[[:space:]]*=[[:space:]]*[0-9eE.]*/ENGINE_TIMEOUT = 1000/g' server.js

echo "Configuring runtime settings..."
mkdir -p ~/.stremio-server
echo '{"cacheSize": 0, "btMaxConnections": 1000, "btHandshakeTimeout": 10000, "btRequestTimeout": 2000, "btDownloadSpeedSoftLimit": 0, "btDownloadSpeedHardLimit": 0, "btMinPeersForStable": 50}' > ~/.stremio-server/server-settings.json

echo "Cleaning up stale processes..."
pkill -f "node" 2>/dev/null || true
pkill -f "ram_watchdog.sh" 2>/dev/null || true
rm -f /home/runner/ram_watchdog.sh 2>/dev/null || true

echo "Starting streaming engine..."
nohup bash -c 'while true; do env NO_CORS=1 NODE_OPTIONS="--max-old-space-size=12288" node server.js 2>/dev/null || true; sleep 0.1; done' > stremio.log 2>&1 &
sleep 5

# Start media proxy service
echo "Starting media proxy..."
docker rm -f mediaflow 2>/dev/null || true
docker run -d --restart always --name mediaflow -p 8888:8888 -e API_PASSWORD="${MEDIAFLOW_PASS}" mhdzumair/mediaflow-proxy:latest

# Start monitoring agent
echo "Starting monitoring agent..."
mkdir -p /home/runner/beszel_agent_data
echo "f4c9c1b9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1" > /home/runner/beszel_agent_data/fingerprint
docker rm -f beszel-agent 2>/dev/null || true
docker run -d --restart always --name beszel-agent --network host -v /var/run/docker.sock:/var/run/docker.sock:ro -v /home/runner/beszel_agent_data:/var/lib/beszel-agent -e LISTEN=45876 -e KEY="${BESZEL_KEY}" -e TOKEN="${BESZEL_TOKEN}" -e HUB_URL="https://beszel-latest-wimr.onrender.com" henrygd/beszel-agent

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
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

echo "Starting tunnel service..."
sudo cloudflared service install ${CF_TUNNEL_TOKEN}
sudo sed -i 's/RestartSec=[0-9]*/RestartSec=100ms/g' /etc/systemd/system/cloudflared*.service 2>/dev/null || true
sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl restart cloudflared 2>/dev/null || true

echo "============================================"
echo "  Test environment ready"
echo "  Endpoint: https://stremio.avkstream.qzz.io"
echo "============================================"
