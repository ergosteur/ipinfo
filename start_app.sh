#!/bin/bash
# Helper script to start Gunicorn manually with a Unix socket

SOCKET_DIR="/run/ipinfo"
SOCKET_FILE="$SOCKET_DIR/ipinfo.sock"
USER="ipinfo"
GROUP="ipinfo"

# Ensure socket directory exists and has correct permissions
if [ ! -d "$SOCKET_DIR" ]; then
    sudo mkdir -p "$SOCKET_DIR"
    sudo chown "$USER:$GROUP" "$SOCKET_DIR"
    sudo chmod 0775 "$SOCKET_DIR"
fi

# Run Gunicorn as the ipinfo user
if [ "$(whoami)" != "$USER" ]; then
    sudo -u "$USER" ./venv/bin/gunicorn \
        --workers 3 \
        --bind unix:"$SOCKET_FILE" \
        app:app \
        --worker-tmp-dir /dev/shm
else
    ./venv/bin/gunicorn \
        --workers 3 \
        --bind unix:"$SOCKET_FILE" \
        app:app \
        --worker-tmp-dir /dev/shm
fi