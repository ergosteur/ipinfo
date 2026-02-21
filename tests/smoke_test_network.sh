#!/usr/bin/env bash
# Network-level smoke test for ipinfo
# Verifies IPv4, IPv6, and Host header validation using curl --resolve

set -euo pipefail

# Work from the ipinfo directory
cd "$(dirname "$0")/.."

TEMP_DIR=$(mktemp -d)
VENV_DIR="$TEMP_DIR/venv"
PORT=8000

echo "--- Setting up temporary environment in $TEMP_DIR ---"
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "--- Installing dependencies ---"
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo "--- Starting Gunicorn on IPv4 and IPv6 sockets ---"
# We use a real domain for testing
export BASE_DOMAIN="example.com"
export STRICT_HOST_CHECK="true"

# Listen on both IPv4 and IPv6 loopback
gunicorn --bind "127.0.0.1:$PORT" --bind "[::1]:$PORT" app:app --workers 1 &
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
while ! nc -z 127.0.0.1 $PORT; do
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "Error: Gunicorn failed to start."
        exit 1
    fi
    sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

# Test Case 1: IPv4 Request to ip.example.com
echo "--- Test 1: IPv4 Request (ip.example.com) ---"
# We use --resolve to map the hostname to 127.0.0.1
RESPONSE_V4=$(curl -s -4 --resolve "ip.example.com:$PORT:127.0.0.1" "http://ip.example.com:$PORT/json")
echo "Response: $RESPONSE_V4"
if echo "$RESPONSE_V4" | grep -q '"IPv4":"127.0.0.1"'; then
    echo "SUCCESS: Correctly identified IPv4 client."
else
    echo "FAILURE: Failed to identify IPv4 client."
    exit 1
fi

# Test Case 2: IPv6 Request to ip.example.com
echo "--- Test 2: IPv6 Request (ip.example.com) ---"
# We use --resolve to map the hostname to [::1]
RESPONSE_V6=$(curl -s -6 --resolve "ip.example.com:$PORT:::1" "http://ip.example.com:$PORT/json")
echo "Response: $RESPONSE_V6"
if echo "$RESPONSE_V6" | grep -q '"IPv6":"::1"'; then
    echo "SUCCESS: Correctly identified IPv6 client."
else
    echo "FAILURE: Failed to identify IPv6 client."
    exit 1
fi

# Test Case 3: Host Validation (ip4.example.com)
echo "--- Test 3: Host Validation (ip4.example.com) ---"
RESPONSE_IP4=$(curl -s -4 --resolve "ip4.example.com:$PORT:127.0.0.1" "http://ip4.example.com:$PORT/json")
echo "Response: $RESPONSE_IP4"
if echo "$RESPONSE_IP4" | grep -q '"HOST":"ip4.example.com'; then
    echo "SUCCESS: Host header correctly accepted."
else
    echo "FAILURE: Host header rejected or incorrect."
    exit 1
fi

# Test Case 4: Host Validation (evil.com) - Should be rejected
echo "--- Test 4: Host Validation (evil.com) ---"
RESPONSE_EVIL=$(curl -s -4 -o /dev/null -w "%{http_code}" --resolve "evil.com:$PORT:127.0.0.1" "http://evil.com:$PORT/")
if [ "$RESPONSE_EVIL" -eq 400 ]; then
    echo "SUCCESS: Unrecognized host correctly rejected with 400."
else
    echo "FAILURE: Evil host was not rejected (Status: $RESPONSE_EVIL)."
    exit 1
fi

echo "--- Network Smoke Test PASSED ---"
