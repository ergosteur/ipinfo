#!/usr/bin/env bash
# Smoke test for manual (non-Docker) deployment path
# Verifies Gunicorn + Unix Socket + Flask app logic

set -euo pipefail

# Work from the ipinfo directory
cd "$(dirname "$0")/.."

TEMP_DIR=$(mktemp -d)
VENV_DIR="$TEMP_DIR/venv"
SOCKET_FILE="$TEMP_DIR/ipinfo.sock"

echo "--- Setting up temporary environment in $TEMP_DIR ---"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "--- Installing dependencies ---"
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo "--- Starting Gunicorn on Unix socket ---"
# Start Gunicorn in the background
# We disable strict host check for the smoke test
export STRICT_HOST_CHECK="false"
export BASE_DOMAIN="ipinfo.zz"

gunicorn --bind "unix:$SOCKET_FILE" app:app --workers 1 &
GUNICORN_PID=$!

# Ensure cleanup on exit
cleanup() {
    echo "--- Cleaning up ---"
    kill "$GUNICORN_PID" || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "--- Waiting for Gunicorn to start ---"
MAX_RETRIES=5
RETRY_COUNT=0
while [ ! -S "$SOCKET_FILE" ]; do
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "Error: Gunicorn failed to start and create socket."
        exit 1
    fi
    sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "--- Verifying application response via Unix socket ---"
# We use --unix-socket to talk directly to Gunicorn
# Note: Host header is still required for Flask routing/CORS but we disabled strict check
RESPONSE=$(curl -s --unix-socket "$SOCKET_FILE" http://localhost/json)

echo "Response received: $RESPONSE"

if echo "$RESPONSE" | grep -q '"IPv4"'; then
    echo "SUCCESS: Application is running and responding correctly over Unix socket."
else
    echo "FAILURE: Unexpected response from application."
    exit 1
fi

echo "--- Smoke test PASSED ---"
