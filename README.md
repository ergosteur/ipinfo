# ipinfo

## Overview

ipinfo is a Python/Flask "what is my IP" service that provides your IP address and related information through a simple web interface. It supports multiple output formats including JSON, plain text, CSV, pfSense compatible output, and themed HTML pages.

## Features

- Displays your IP address and related info.
- Multiple output formats: JSON, text, CSV, pfSense.
- Themed web interface with different visual styles, including a Windows 98 theme.
- Easy deployment with Docker Compose.
- Supports multiple Traefik deployment modes for HTTPS.
- Configuration through environment variables.

The Windows 98 theme is inspired by and uses the `98.js` project (https://github.com/1j01/98) to recreate the classic UI look and feel.

## Deployment

**Note:**  
For accurate detection of client IP addresses, ipinfo is best deployed on a VPS or VM with its own public IP address. The default Traefik configuration requires that ports 80 and 443 are available on the Docker host. If you prefer not to use the included Traefik setup, the Flask app can also be integrated into your own existing reverse proxy configuration.

This project is designed to be deployed using Docker Compose. A legacy systemd service (`ipinfo.service`) is included for older setups, but Docker deployment is recommended for ease of use and portability.

### Quickstart

```bash
cp example.env .env
docker compose up -d --build
```

## Docker Compose Modes

There are three primary modes for deploying with Traefik:

1. **HTTP-01 (Default)**  
   Uses Traefik's HTTP-01 challenge to obtain Let's Encrypt certificates automatically. Suitable for most standard setups.

2. **DNS-01 Cloudflare (Wildcard)**  
   Uses Traefik's DNS-01 challenge with Cloudflare to obtain wildcard certificates. Requires Cloudflare API tokens configured via environment variables.

3. **LAN Development Mode**  
   Intended for local development on a LAN. Uses ephemeral self-signed certificates instead of Let's Encrypt.

## Deployment without Docker

A `deploy.sh` script is provided to deploy ipinfo without Docker. This script installs necessary dependencies, sets up the Flask application with systemd, and configures Caddy as a reverse proxy for HTTPS.

### Usage

- First deployment with domain and email:

  ```bash
  ./deploy.sh --domain example.com --email you@example.com
  ```

- Update an existing deployment:

  ```bash
  ./deploy.sh --update
  ```

### Cloudflare DNS Automation

The script supports optional Cloudflare DNS automation to simplify DNS setup and enable wildcard DNS-01 challenges in Caddy.

- Use the following arguments to enable Cloudflare integration:

  ```bash
  ./deploy.sh --domain example.com --email you@example.com --cf-token YOUR_CLOUDFLARE_API_TOKEN --cf-zone yourdomain.com
  ```

- This will automatically configure DNS records for the `ip.`, `ip4.`, and `ip6.` subdomains and set up wildcard DNS-01 challenges for TLS certificates.

- If Cloudflare arguments are not provided, you must manually create DNS records pointing these subdomains to your VPS IP address.

## Configuration via `.env`

The application and Traefik are configured via environment variables in a `.env` file:

- `BASE_DOMAIN` — The base domain name for your deployment.
- `LETSENCRYPT_EMAIL` — Email address used for Let's Encrypt registration.
- Cloudflare tokens (optional) for DNS-01 challenge mode:
  - `CF_API_EMAIL`
  - `CF_API_KEY`
  - or `CF_DNS_API_TOKEN`

Refer to `example.env` for all configurable variables.

## License

Like the upstream 98.css, this project is not yet licensed.  
This project is currently [source-available / shared source](https://en.wikipedia.org/wiki/Source-available_software), but not [open source](https://en.wikipedia.org/wiki/Open-source_software).

## Development

To develop or customize the application:

- Modify the Flask app source code.
- Adjust themes or output formats as needed.
- Use the Docker Compose setup to build and test changes quickly.
- For local development, consider using the LAN mode for easier TLS setup.

---

Enjoy using ipinfo for your IP address needs!
