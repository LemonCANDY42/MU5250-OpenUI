#!/bin/bash
set -euo pipefail

# Default settings based on deploy.sh
DEVICE="192.168.0.1"
SSH_PORT=2222
TARGET_DIR=${1:-"/data/www"}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WEB_DIR="$ROOT_DIR/web-app"

fail() { echo "Error: $1" >&2; exit 1; }

command -v node >/dev/null 2>&1 || fail "Node.js is required (^20.19.0 or >=22.12.0)."
command -v npm >/dev/null 2>&1 || fail "npm is required to build the dashboard."
node "$WEB_DIR/tools/check-node-version.mjs"

# Install from the lockfile and build the dashboard first.
echo "Building the dashboard..."
cd "$WEB_DIR"
npm ci
npm run build
cd "$ROOT_DIR"

# Ensure build succeeded
[ -d "$WEB_DIR/dist" ] || fail "web-app/dist directory not found. Build failed?"

echo "Deploying dashboard to root@$DEVICE:$TARGET_DIR via SSH tar pipe (Port $SSH_PORT)..."

# The device's dropbear has no sftp-server and no remote scp binary, so scp
# fails. Stream the dist tree over ssh instead (same pattern as setup.sh).
SSH="ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts.d/zte root@$DEVICE"
tar czf - -C "$WEB_DIR/dist" . | $SSH "mkdir -p $TARGET_DIR && tar xzf - -C $TARGET_DIR"

# Keep mobile.html for compatibility with older installs, then restart only
# the isolated dashboard listener. Restarting ZTE's stock uhttpd cannot
# reliably start a second UCI instance because its zwrt_uhttpd object is a
# singleton.
$SSH "test -x /data/bin/dashboard-uhttpd && test -x /data/local/tmp/start_dashboard.sh" \
  || fail "Dashboard server is not installed. Run scripts/zharden.sh first."
$SSH "cp $TARGET_DIR/index.html $TARGET_DIR/mobile.html && sh /data/local/tmp/start_dashboard.sh"

echo "Verifying dashboard on the device..."
sleep 1
$SSH "/usr/bin/curl --fail --silent --show-error --connect-timeout 5 --max-time 10 http://127.0.0.1:8080/ | grep -q '<div id=\"root\"></div>'"

echo "Dashboard deploy successful: http://$DEVICE:8080"
