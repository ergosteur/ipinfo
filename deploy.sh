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
UPDATE_MODE=0

usage() {
  echo "Usage: $0 [-d domain] [-e email] [-t cf_token] [-z cf_zone] [-u] [-h]"
  echo ""
  echo "Options:"
  echo "  -d DOMAIN      Set the domain name (default: ip.example.com or BASE_DOMAIN env)"
  echo "  -e EMAIL       Set the email for TLS certificates"
  echo "  -t CF_TOKEN    Cloudflare API token for DNS challenge and DNS record management"
  echo "  -z CF_ZONE     Cloudflare zone ID for DNS record management"
  echo "  -u             Update mode (skip installation and venv creation)"
  echo "  -h             Show this help message and exit"
}

while getopts ":d:e:t:z:uh" opt; do
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

  # --- install Caddy (official repo) ---
  if ! command -v caddy &>/dev/null; then
    echo "Installing Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update
    apt install -y caddy
  fi
fi

# --- setup app directory ---
mkdir -p "$APP_DIR"
chown "$USER":"$USER" "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  git clone https://github.com/ergosteur/ipinfo.git "$APP_DIR"
else
  cd "$APP_DIR" && git pull
fi

cd "$APP_DIR"
if [[ $UPDATE_MODE -eq 0 ]]; then
  $PYTHON_BIN -m venv venv
fi
. venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# --- systemd service ---
tee /etc/systemd/system/ipinfo.service >/dev/null <<EOF
[Unit]
Description=ipinfo Flask app
After=network.target

[Service]
User=$USER
Environment=BASE_DOMAIN=$DOMAIN
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -b 127.0.0.1:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ipinfo.service

# --- caddy config ---
if [[ -n "$CF_TOKEN" ]]; then
  # Configure Caddy with Cloudflare DNS challenge and wildcard domain
  tee /etc/caddy/Caddyfile >/dev/null <<EOF
{
    email $EMAIL
    acme_dns cloudflare
}

*.${DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
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
EOF
  else
    tee /etc/caddy/Caddyfile >/dev/null <<EOF
*.${DOMAIN} {
    reverse_proxy 127.0.0.1:5000
}
EOF
  fi
fi

systemctl reload caddy

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