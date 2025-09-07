import os
from flask import Flask, request, jsonify, render_template, make_response, send_from_directory, Response, abort
from flask_cors import CORS
import socket
import csv
from io import StringIO
from datetime import datetime

# Domain configuration
BASE_DOMAIN = os.environ.get("BASE_DOMAIN", "1qaz.ca")

# CORS origins for subdomains
CORS_ORIGINS = [
    f"https://ip.{BASE_DOMAIN}",
    f"https://ip4.{BASE_DOMAIN}",
    f"https://ip6.{BASE_DOMAIN}",
]

app = Flask(__name__)

# Dynamically set CORS origins based on BASE_DOMAIN
CORS(app, resources={r"/*": {"origins": CORS_ORIGINS}})

# Host validation
ALLOWED_HOSTS = {
    f"ip.{BASE_DOMAIN}",
    f"ip4.{BASE_DOMAIN}",
    f"ip6.{BASE_DOMAIN}",
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
    return {"info": info, "BASE_DOMAIN": BASE_DOMAIN}

def get_ip_info(request):
    ipv4 = None
    ipv6 = None

    x_forwarded_for = request.headers.get('X-Forwarded-For')
    if x_forwarded_for:
        ips = [ip.strip() for ip in x_forwarded_for.split(',')]
        for ip in ips:
            try:
                socket.inet_pton(socket.AF_INET, ip)
                ipv4 = ip
            except socket.error:
                try:
                    socket.inet_pton(socket.AF_INET6, ip)
                    ipv6 = ip
                except socket.error:
                    pass
    else:
        try:
            socket.inet_pton(socket.AF_INET, request.remote_addr)
            ipv4 = request.remote_addr
        except socket.error:
            try:
                socket.inet_pton(socket.AF_INET6, request.remote_addr)
                ipv6 = request.remote_addr
            except socket.error:
                pass

    hostname_ipv4 = "None"
    hostname_ipv6 = "None"

    if ipv4:
        try:
            hostname_ipv4 = socket.getfqdn(ipv4)
        except socket.gaierror:
            hostname_ipv4 = "Hostname not found"

    if ipv6:
        try:
            hostname_ipv6 = socket.getfqdn(ipv6)
        except socket.gaierror:
            hostname_ipv6 = "Hostname not found"

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
    info = get_ip_info(request)
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
    info = get_ip_info(request)
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
        "/98"
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
