#!/bin/bash

SOCKET_DIR="/run/ipinfo"
SOCKET_FILE="$SOCKET_DIR/ipinfo.sock"
USER="ipinfo"
GROUP="www-data"

# Create the socket directory if it doesn't exist
if [ ! -d "$SOCKET_DIR" ]; then
    mkdir -p "$SOCKET_DIR"
    chown "$USER:$GROUP" "$SOCKET_DIR"
    chmod 0775 "$SOCKET_DIR"
fi

# Check if running as the correct user
if [ "$(whoami)" != "$USER" ]; then
    # Run Gunicorn as the specified user using sudo
    sudo -u "$USER" gunicorn --bind unix:"$SOCKET_FILE" app:app --worker-tmp-dir /dev/shm
else
    # Run Gunicorn directly
    gunicorn --bind unix:"$SOCKET_FILE" app:app --worker-tmp-dir /dev/shm
fi
