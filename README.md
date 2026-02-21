# ipinfo

## Overview

ipinfo is a Python/Flask "what is my IP" service that provides your IP address and related information through a simple web interface. It supports multiple output formats including JSON, plain text, CSV, pfSense compatible output, and themed HTML pages.

## Features

- Displays your IP address and related info.
- Multiple output formats: JSON, text, CSV, pfSense.
- Themed web interface with different visual styles, including a Windows 98 theme.
- **Security:** Runs as a non-root user in both Docker and manual deployments.
- **Rate Limiting:** Built-in rate limiting with support for IP whitelisting.
- **Automated Tests:** Includes a comprehensive pytest suite.
- Easy deployment with Docker Compose.
- Supports multiple Traefik deployment modes for HTTPS.
- Configuration through environment variables.

The Windows 98 theme is inspired by and uses the `98.js` project (https://github.com/1j01/98) to recreate the classic UI look and feel.

## Deployment

**Note:**  
For accurate detection of client IP addresses, ipinfo is best deployed on a VPS or VM with its own public IP address. The default Traefik or Caddy configuration requires that ports 80 and 443 are available on the host. If you prefer not to use the included Traefik setup, the Flask app can also be integrated into your own existing reverse proxy configuration.

This project can be deployed using Docker Compose, or as a systemd service.

### Quickstart with systemd
The `deploy.sh` script autonomously installs all dependencies (including Caddy), sets up the `ipinfo` user, and configures the systemd service.

```bash
git clone https://github.com/ergosteur/ipinfo.git
cd ipinfo/
sudo ./deploy.sh -d yourdomain.com -e you@example.com
```

### Quickstart with docker compose

```bash
git clone https://github.com/ergosteur/ipinfo.git
cd ipinfo/
cp example.env .env
# Edit .env and set your BASE_DOMAIN
docker compose up -d
```

## DNS Setup

For the application to function correctly and provide separate IPv4/IPv6 endpoints, you should configure the following DNS records in your DNS provider:

| Subdomain | Record Type | Points to | Description |
| :--- | :--- | :--- | :--- |
| `ip.<yourdomain>` | **A** | Your Server IPv4 | Main entry point (Dual-stack) |
| `ip.<yourdomain>` | **AAAA** | Your Server IPv6 | Main entry point (Dual-stack) |
| `ip4.<yourdomain>` | **A** | Your Server IPv4 | Forced IPv4-only endpoint |
| `ip6.<yourdomain>` | **AAAA** | Your Server IPv6 | Forced IPv6-only endpoint |

*Note: Ensure that your server has a public IPv6 address if you intend to use the IPv6/AAAA records.*

## Docker Compose Modes

There are three primary modes for deploying with Traefik:

1. **HTTP-01 (Default)**  
   Uses Traefik's HTTP-01 challenge to obtain Let's Encrypt certificates automatically. Suitable for most standard setups.

2. **DNS-01 Cloudflare (Wildcard)**  
   Uses Traefik's DNS-01 challenge with Cloudflare to obtain wildcard certificates. Requires Cloudflare API tokens configured via environment variables.

3. **LAN Development Mode**  
   Intended for local development on a LAN. Uses ephemeral self-signed certificates instead of Let's Encrypt.

## Deployment without Docker

A `deploy.sh` script is provided to deploy ipinfo without Docker. This script installs necessary dependencies, sets up the Flask application with systemd (running under a dedicated `ipinfo` user), and configures Caddy as a reverse proxy for HTTPS.

### Usage

- First deployment with domain and email:

  ```bash
  ./deploy.sh -d example.com -e you@example.com -w "1.1.1.1,2.2.2.2"
  ```

- Update an existing deployment:

  ```bash
  ./deploy.sh -u
  ```

### Cloudflare DNS Automation

The script supports optional Cloudflare DNS automation to simplify DNS setup and enable wildcard DNS-01 challenges in Caddy.

- Use the following arguments to enable Cloudflare integration:

  ```bash
  ./deploy.sh -d example.com -e you@example.com -t YOUR_CF_TOKEN -z YOUR_CF_ZONE
  ```

## Configuration via `.env`

The application and infrastructure are configured via environment variables in a `.env` file:

- `BASE_DOMAIN` — The base domain name for your deployment.
- `LETSENCRYPT_EMAIL` — Email address used for Let's Encrypt registration.
- `WHITELIST_IPS` — Comma-separated list of IPs to exempt from rate limiting.
- `STRICT_HOST_CHECK` — Set to `false` to disable host validation (default: `true`).
- Cloudflare tokens (optional) for DNS-01 challenge mode:
  - `CF_DNS_API_TOKEN` (for Traefik)
  - `CF_API_KEY`

Refer to `example.env` for all configurable variables.

## Development

To develop or customize the application:

1.  **Install dependencies:**
    ```bash
    pip install -r requirements.txt
    ```
2.  **Run tests:**
    ```bash
    pytest
    ```
3.  **Run locally:**
    ```bash
    # Set your real domain or a dummy one
    export BASE_DOMAIN="ip.example.com"
    # Disable strict host check for easier local testing
    export STRICT_HOST_CHECK="false"
    python app.py
    ```

## License

Like the upstream 98.css, this project is not yet licensed.  
This project is currently [source-available / shared source](https://en.wikipedia.org/wiki/Source-available_software), but not [open source](https://en.wikipedia.org/wiki/Open-source_software).

---

Enjoy using ipinfo for your IP address needs!