import os
import ipaddress
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from flask import Flask, request, jsonify, render_template, make_response, send_from_directory, Response, abort
from flask_cors import CORS
from flask_limiter import Limiter
import socket
import csv
from io import StringIO
from datetime import datetime

# Domain configuration
BASE_DOMAIN = os.environ.get("BASE_DOMAIN", "1qaz.ca")

# Number of reverse proxies in front of the app that each append to X-Forwarded-For
# (1 for Traefik or Caddy alone, 2 for Cloudflare -> Traefik). Only the entry that
# the outermost trusted proxy appended is believed; anything to its left is
# client-supplied and can be forged. Set to 0 to ignore X-Forwarded-For entirely.
TRUSTED_PROXY_COUNT = max(0, int(os.environ.get("TRUSTED_PROXY_COUNT", "1")))

# CORS origins for subdomains
CORS_ORIGINS = [
    f"https://ip.{BASE_DOMAIN}",
    f"https://ip4.{BASE_DOMAIN}",
    f"https://ip6.{BASE_DOMAIN}",
]

app = Flask(__name__)

def get_client_ip():
    """Return the client IP as seen by the outermost trusted proxy.

    X-Forwarded-For is "client-supplied..., real client, proxy1, ..." where each
    trusted proxy appended the address it received the request from. Counting
    from the right by TRUSTED_PROXY_COUNT skips anything a client made up.
    """
    xff = request.headers.get('X-Forwarded-For')
    if xff and TRUSTED_PROXY_COUNT:
        ips = [ip.strip() for ip in xff.split(',') if ip.strip()]
        if ips:
            candidate = ips[-min(TRUSTED_PROXY_COUNT, len(ips))]
            try:
                addr = ipaddress.ip_address(candidate)
                return str(addr.ipv4_mapped or addr) if addr.version == 6 else str(addr)
            except ValueError:
                pass
    return request.remote_addr

# Rate Limiting
def get_client_ip_for_limiter():
    return get_client_ip()

limiter = Limiter(
    key_func=get_client_ip_for_limiter,
    app=app,
    default_limits=["5000 per day", "200 per hour"],
    storage_uri="memory://",
)

@limiter.request_filter
def is_whitelisted():
    """Check if the client IP is whitelisted."""
    client_ip = get_client_ip_for_limiter()
    whitelist = os.environ.get("WHITELIST_IPS", "").split(",")
    return client_ip in [ip.strip() for ip in whitelist if ip.strip()]

# Dynamically set CORS origins based on BASE_DOMAIN
CORS(app, resources={r"/*": {"origins": CORS_ORIGINS}})

# Host validation
ALLOWED_HOSTS = {
    f"ip.{BASE_DOMAIN}",
    f"ip4.{BASE_DOMAIN}",
    f"ip6.{BASE_DOMAIN}",
    "localhost",
    "127.0.0.1",
}

@app.before_request
def enforce_host_validation():
    strict_check = os.environ.get("STRICT_HOST_CHECK", "true").lower()
    if strict_check != "false":
        # Always strip port and lowercase
        req_host = request.host.split(":")[0].lower()
        if req_host not in ALLOWED_HOSTS:
            return make_response(
                f"Host '{req_host}' is not accepted. Allowed hosts: {', '.join(ALLOWED_HOSTS)}",
                400,
            )

def template_context(info):
    """Helper to provide template context including BASE_DOMAIN."""
    return {
        "info": info,
        "BASE_DOMAIN": BASE_DOMAIN,
        "CURRENT_HOST": request.host,
        "NO_IP_VERSION_SUBDOMAINS": os.environ.get("NO_IP_VERSION_SUBDOMAINS", "false").lower() == "true",
        "WIN98_DEFAULT": os.environ.get("WIN98_DEFAULT", "false").lower() == "true",
    }

# Reverse DNS: getfqdn() has no timeout and blocks the whole (sync) worker, so run it
# in a small thread pool with a deadline and cache results, failures included.
RDNS_TIMEOUT = 2.0
RDNS_CACHE_TTL = 300
RDNS_CACHE_MAX = 1024
_rdns_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="rdns")
_rdns_cache = {}

def lookup_hostname(ip):
    """Reverse-resolve ip, giving up after RDNS_TIMEOUT seconds."""
    now = time.monotonic()
    cached = _rdns_cache.get(ip)
    if cached and cached[0] > now:
        return cached[1]
    try:
        hostname = _rdns_pool.submit(socket.getfqdn, ip).result(timeout=RDNS_TIMEOUT)
    except (FutureTimeout, OSError):
        hostname = "Hostname not found"
    if len(_rdns_cache) >= RDNS_CACHE_MAX:
        _rdns_cache.clear()
    _rdns_cache[ip] = (now + RDNS_CACHE_TTL, hostname)
    return hostname

def get_ip_info(request, resolve_hostnames=True):
    ipv4 = None
    ipv6 = None

    x_forwarded_for = request.headers.get('X-Forwarded-For')
    client_ip = get_client_ip()
    try:
        version = ipaddress.ip_address(client_ip).version
    except ValueError:
        version = None
    if version == 4:
        ipv4 = client_ip
    elif version == 6:
        ipv6 = client_ip

    hostname_ipv4 = "None"
    hostname_ipv6 = "None"

    if resolve_hostnames:
        if ipv4:
            hostname_ipv4 = lookup_hostname(ipv4)
        if ipv6:
            hostname_ipv6 = lookup_hostname(ipv6)

    user_agent = request.headers.get('User-Agent')
    language = request.headers.get('Accept-Language')
    encodings = request.headers.get('Accept-Encoding')
    host = request.headers.get('Host')
    cf_connecting_ip = request.headers.get('CF-Connecting-IP')  # Get the CF-Connecting-IP header

    info = {
        'IPv4': ipv4,
        'HOSTNAME_IPv4': hostname_ipv4,
        'IPv6': ipv6,
        'HOSTNAME_IPv6': hostname_ipv6,
        'USER_AGENT': user_agent,
        'LANGUAGE': language,
        'ENCODINGS': encodings,
        'X-Forwarded-For': x_forwarded_for,
        'HOST': host,
    }

    if cf_connecting_ip:  # Add the header to the info dictionary if present
        info['CF_CONNECTING_IP'] = cf_connecting_ip

    return info

@app.route('/')
def html_info():
    info = get_ip_info(request)
    if os.environ.get("WIN98_DEFAULT", "false").lower() == "true":
        return render_template('98/index.html', **template_context(info))
    return render_template('info.html', **template_context(info))

@app.route('/standard')
def standard_info():
    info = get_ip_info(request)
    return render_template('info.html', **template_context(info))

@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.root_path, 'static'),
                               'favicon.ico', mimetype='image/vnd.microsoft.icon')

@app.route('/json')
def json_info():
    info = get_ip_info(request)
    return jsonify(info)

@app.route('/txt')
def text_info():
    info = get_ip_info(request)
    text = "\n".join([f"{key}: {value}" for key, value in info.items()])
    return make_response(text, {'Content-Type': 'text/plain'})

@app.route('/iponly')
def iponly_info():
    info = get_ip_info(request, resolve_hostnames=False)
    text = info.get('IPv4') or info.get('IPv6')
    return make_response(text, {'Content-Type': 'text/plain'})

@app.route('/csv')
def csv_info():
    info = get_ip_info(request)
    si = StringIO()
    cw = csv.writer(si)
    cw.writerow(["Key", "Value"])  # Add header row
    for key, value in info.items():
        cw.writerow([key, value])
    #cw.writerow(info.keys())
    #cw.wrierow(info.values())
    output = si.getvalue()
    return make_response(output, {'Content-Type': 'text/plain'})

# pfSense Dynamic DNS CheckIP
@app.route('/pfsense')
def pfsense_ip_check():
    info = get_ip_info(request, resolve_hostnames=False)
    client_ip = info.get('IPv4') or info.get('IPv6')  # Get IPv4 or IPv6

    if client_ip:
        html_response = f"""
        <html>
        <head><title>Current IP Check</title></head>
        <body>Current IP Address: {client_ip}</body>
        </html>
        """
        return html_response
    else:
        return "Could not determine client IP", 500


# fun themes
@app.route('/98')
def windows98_info():
    info = get_ip_info(request)
    return render_template('98/index.html', **template_context(info))

if __name__ == '__main__':
    # Not used with Gunicorn
    pass

# SEO static
# Route for robots.txt
@app.route('/robots.txt')
def serve_robots_txt():
    content = f"""User-agent: *
Disallow: https://ip4.{BASE_DOMAIN}/
Disallow: https://ip6.{BASE_DOMAIN}/

Sitemap: https://ip.{BASE_DOMAIN}/sitemap.xml
"""
    return Response(content, mimetype="text/plain")

# Route for sitemap.xml
@app.route('/sitemap.xml')
def serve_sitemap_xml():
    now = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    base_url = f"https://ip.{BASE_DOMAIN}"
    urls = [
        "/",
        "/json",
        "/txt",
        "/csv",
        "/iponly",
        "/pfsense",
        "/98",
        "/standard"
    ]
    urlset = ""
    for url in urls:
        urlset += f"""
    <url>
        <loc>{base_url}{url}</loc>
        <lastmod>{now}</lastmod>
        <changefreq>daily</changefreq>
        <priority>0.8</priority>
    </url>"""
    sitemap_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urlset}
</urlset>"""
    return Response(sitemap_xml, mimetype="application/xml")
