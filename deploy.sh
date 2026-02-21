#!/usr/bin/env bash
# Deploy ipinfo Flask app with Caddy on Debian/Ubuntu VPS (no Docker)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Please run with sudo or as root user."
  exit 1
fi

APP_DIR="/srv/ipinfo"
PYTHON_BIN="python3"
DOMAIN=""
EMAIL=""
CF_TOKEN=""
CF_ZONE=""
WHITELIST_IPS=""
UPDATE_MODE=0

usage() {
  echo "Usage: $0 [-d domain] [-e email] [-t cf_token] [-z cf_zone] [-w whitelist_ips] [-u] [-h]"
  echo ""
  echo "Options:"
  echo "  -d DOMAIN         Set the domain name (default: ip.example.com or BASE_DOMAIN env)"
  echo "  -e EMAIL          Set the email for TLS certificates"
  echo "  -t CF_TOKEN       Cloudflare API token for DNS challenge and DNS record management"
  echo "  -z CF_ZONE        Cloudflare zone ID for DNS record management"
  echo "  -w WHITELIST_IPS  Comma-separated list of IPs to whitelist from rate limiting"
  echo "  -u                Update mode (skip installation and venv creation)"
  echo "  -h                Show this help message and exit"
}

while getopts ":d:e:t:z:w:uh" opt; do
  case $opt in
    d)
      DOMAIN="$OPTARG"
      ;;
    e)
      EMAIL="$OPTARG"
      ;;
    t)
      CF_TOKEN="$OPTARG"
      ;;
    z)
      CF_ZONE="$OPTARG"
      ;;
    w)
      WHITELIST_IPS="$OPTARG"
      ;;
    u)
      UPDATE_MODE=1
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done

# Set DOMAIN from environment variable if not set by argument
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="${BASE_DOMAIN:-ip.example.com}"
fi

if [[ $UPDATE_MODE -eq 0 ]]; then
  # --- install dependencies ---
  apt update
  apt install -y python3 python3-venv python3-pip git curl debian-keyring debian-archive-keyring apt-transport-https jq

  # --- create ipinfo user ---
  if ! id -u ipinfo &>/dev/null; then
    groupadd -r ipinfo
    useradd -r -g ipinfo -d "$APP_DIR" -s /sbin/nologin ipinfo
  fi

  # --- install Go if missing or too old ---
  install_go() {
    local required_version="1.25"
    local go_version=""
    if command -v go &>/dev/null; then
      go_version=$(go version | awk '{print $3}' | sed 's/go//')
    fi

    version_ge() {
      # returns 0 if $1 >= $2
      [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
    }

    if [[ -z "$go_version" ]] || ! version_ge "$go_version" "$required_version"; then
      echo "Installing Go 1.25 or newer..."

      GO_ARCH="amd64"
      GO_OS="linux"
      GO_VERSION="1.25.1"

      # Clean previous Go installation if exists
      if [ -d /usr/local/go ]; then
        rm -rf /usr/local/go
      fi

      TMPDIR=$(mktemp -d)
      GO_TAR="go${GO_VERSION}.${GO_OS}-${GO_ARCH}.tar.gz"
      curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "${TMPDIR}/${GO_TAR}"
      tar -C /usr/local -xzf "${TMPDIR}/${GO_TAR}"
      rm -rf "${TMPDIR}"

      export PATH="/usr/local/go/bin:$PATH"

      # Verify installation
      if ! command -v go &>/dev/null; then
        echo "Go installation failed"
        exit 1
      fi
    else
      echo "Go version $go_version is already installed and meets requirement."
    fi
  }

  install_go

  # --- install Caddy (with Cloudflare DNS support) ---
  if ! command -v caddy &>/dev/null; then
    echo "Installing xcaddy..."
    apt install -y git

    # Install xcaddy
    export PATH="/usr/local/go/bin:$PATH"
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    export PATH=$PATH:/root/go/bin

    echo "Building custom Caddy with Cloudflare DNS module..."
    mkdir -p "$APP_DIR/bin"
    xcaddy build \
      --with github.com/caddy-dns/cloudflare

    # Install Caddy binary
    mv caddy "$APP_DIR/bin/caddy"

    # Create systemd service for Caddy
    tee /etc/systemd/system/caddy.service >/dev/null <<EOF
[Unit]
Description=Caddy web server
After=network.target

[Service]
User=$USER
EOF
if [[ -n "$CF_TOKEN" ]]; then
  tee -a /etc/systemd/system/caddy.service >/dev/null <<EOF
Environment=CLOUDFLARE_API_TOKEN=$CF_TOKEN
EOF
fi
tee -a /etc/systemd/system/caddy.service >/dev/null <<EOF
ExecStart=$APP_DIR/bin/caddy run --environ --config /etc/caddy/Caddyfile
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now caddy.service
  fi
fi

# --- setup app directory ---
mkdir -p "$APP_DIR"
chown -R ipinfo:ipinfo "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  git clone https://github.com/ergosteur/ipinfo.git "$APP_DIR"
  chown -R ipinfo:ipinfo "$APP_DIR"
else
  cd "$APP_DIR" && git pull
  chown -R ipinfo:ipinfo "$APP_DIR"
fi

cd "$APP_DIR"
if [[ $UPDATE_MODE -eq 0 ]]; then
  sudo -u ipinfo $PYTHON_BIN -m venv venv
fi
sudo -u ipinfo venv/bin/pip install --upgrade pip
sudo -u ipinfo venv/bin/pip install -r requirements.txt

# --- systemd service ---
tee /etc/systemd/system/ipinfo.service >/dev/null <<EOF
[Unit]
Description=ipinfo Flask app
After=network.target

[Service]
User=ipinfo
Group=ipinfo
Environment=BASE_DOMAIN=$DOMAIN
Environment=WHITELIST_IPS=$WHITELIST_IPS
WorkingDirectory=$APP_DIR

RuntimeDirectory=ipinfo
RuntimeDirectoryMode=0775

ExecStartPre=/bin/mkdir -p $APP_DIR/logs
ExecStartPre=/bin/chown ipinfo:ipinfo $APP_DIR/logs

UMask=002

ExecStart=$APP_DIR/venv/bin/gunicorn \\
  --workers 3 \\
  --bind unix:/run/ipinfo/ipinfo.sock \\
  --access-logfile $APP_DIR/logs/access.log \\
  --error-logfile $APP_DIR/logs/error.log \\
  app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ipinfo.service

# Ensure /etc/caddy directory exists before writing Caddyfile
mkdir -p /etc/caddy

# --- caddy config ---
if [[ -n "$CF_TOKEN" ]]; then
  # Configure Caddy with Cloudflare DNS challenge and wildcard domain
  tee /etc/caddy/Caddyfile >/dev/null <<EOF
{
    email $EMAIL
}

*.${DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    reverse_proxy 127.0.0.1:5000
}

http://*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}
EOF
else
  # Normal HTTPS with wildcard domain
  if [[ -n "$EMAIL" ]]; then
    tee /etc/caddy/Caddyfile >/dev/null <<EOF
{
    email $EMAIL
}

*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}

http://*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}
EOF
  else
    tee /etc/caddy/Caddyfile >/dev/null <<EOF
*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}

http://*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}
EOF
  fi
fi

if [[ $UPDATE_MODE -ne 0 ]]; then
  systemctl restart caddy.service
fi

# --- Cloudflare DNS records setup ---
DNS_UPDATED=0
if [[ -n "$CF_TOKEN" && -n "$CF_ZONE" ]]; then
  echo "Configuring Cloudflare DNS records..."

  # Export token for Caddy DNS provider
  export CLOUDFLARE_API_TOKEN="$CF_TOKEN"

  # Detect public IPv4 and IPv6 addresses
  PUBLIC_IPV4=$(curl -4 -s https://api64.ipify.org || true)
  PUBLIC_IPV6=$(curl -6 -s https://api64.ipify.org || true)

  # Function to create or update DNS record
  cf_upsert_dns_record() {
    local type=$1
    local name=$2
    local content=$3

    if [[ -z "$content" ]]; then
      echo "No $type address detected for $name, skipping."
      return
    fi

    # Check if record exists
    local record_id
    record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=$type&name=$name" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

    if [[ -n "$record_id" ]]; then
      # Update record
      echo "Updating $type record for $name to $content"
      curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$record_id" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":120,\"proxied\":false}" >/dev/null
    else
      # Create record
      echo "Creating $type record for $name to $content"
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":120,\"proxied\":false}" >/dev/null
    fi
  }

  cf_upsert_dns_record A "ip.$DOMAIN" "$PUBLIC_IPV4"
  cf_upsert_dns_record A "ip4.$DOMAIN" "$PUBLIC_IPV4"
  cf_upsert_dns_record AAAA "ip6.$DOMAIN" "$PUBLIC_IPV6"

  DNS_UPDATED=1
fi

echo "Deployment complete. Visit: https://$DOMAIN"

# --- Post deployment check ---
if [[ -n "$DOMAIN" && -n "$EMAIL" && -n "$CF_TOKEN" && -n "$CF_ZONE" && $DNS_UPDATED -eq 1 ]]; then
  echo "Performing quick check for https://ip.$DOMAIN/json ..."
  if curl -f "https://ip.$DOMAIN/json" >/dev/null 2>&1; then
    echo "Quick check succeeded: https://ip.$DOMAIN/json is reachable."
  else
    echo "Warning: https://ip.$DOMAIN/json is not reachable yet. DNS propagation or Caddy setup may still be in progress."
  fi
else
  echo ""
  echo "Cloudflare DNS automation not fully configured."
  echo "Please manually create the following DNS records in your Cloudflare zone $CF_ZONE:"
  echo "  A     ip.$DOMAIN    -> your server's public IPv4 address"
  echo "  A     ip4.$DOMAIN   -> your server's public IPv4 address"
  echo "  AAAA  ip6.$DOMAIN   -> your server's public IPv6 address (if available)"
fi