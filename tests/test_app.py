import pytest
import sys
import os

# Add the parent directory to sys.path to find app.py
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app as app_module
from app import app

@pytest.fixture
def client():
    app.config['TESTING'] = True
    # Disable rate limiting during tests
    app.config['RATELIMIT_ENABLED'] = False
    with app.test_client() as client:
        yield client

def test_home(client):
    """Test the home page HTML."""
    rv = client.get('/')
    assert rv.status_code == 200
    # Check for some content that should be there
    assert b"html" in rv.data.lower()

def test_json(client):
    """Test the JSON endpoint."""
    rv = client.get('/json')
    assert rv.status_code == 200
    assert rv.is_json
    # Basic check for structure
    data = rv.get_json()
    assert "IPv4" in data
    assert "USER_AGENT" in data

def test_txt(client):
    """Test the plain text endpoint."""
    rv = client.get('/txt')
    assert rv.status_code == 200
    assert b"IPv4:" in rv.data or b"IPv6:" in rv.data

def test_iponly(client):
    """Test the IP only endpoint."""
    rv = client.get('/iponly')
    assert rv.status_code == 200
    # Should be a short string, likely an IP
    text = rv.data.decode('utf-8').strip()
    assert len(text) > 0
    # Rough check for IP format (dots or colons)
    assert "." in text or ":" in text

def test_csv(client):
    """Test the CSV endpoint."""
    rv = client.get('/csv')
    assert rv.status_code == 200
    text = rv.data.decode('utf-8')
    assert "Key,Value" in text
    assert "IPv4," in text or "IPv6," in text

def test_pfsense(client):
    """Test the pfSense endpoint."""
    rv = client.get('/pfsense')
    # Use a mock IP to ensure it returns 200
    # But since we are local, it might return 127.0.0.1 which is fine
    assert rv.status_code == 200
    assert b"Current IP Address" in rv.data

def test_host_validation(client):
    """Test host validation middleware."""
    # This might fail if STRICT_HOST_CHECK is not handled in tests correctly
    # app.py reads env var STRICT_HOST_CHECK.
    # By default it is "true".
    # And allowed hosts are ip.BASE_DOMAIN etc.
    # BASE_DOMAIN defaults to 1qaz.ca.
    # So localhost and 127.0.0.1 are allowed.
    
    # Test a bad host
    rv = client.get('/', headers={'Host': 'evil.com'})
    assert rv.status_code == 400
    assert b"not accepted" in rv.data

    # Test a good host
    rv = client.get('/', headers={'Host': 'localhost'})
    assert rv.status_code == 200


# --- Client IP detection (X-Forwarded-For trust) ---

def client_ip(client, xff):
    return client.get('/json', headers={'X-Forwarded-For': xff}).get_json()

def test_xff_forged_entries_ignored(client):
    """With one trusted proxy only the rightmost entry (appended by the proxy) counts."""
    data = client_ip(client, '8.8.8.8, 203.0.113.9')
    assert data['IPv4'] == '203.0.113.9'
    assert data['IPv6'] is None

def test_xff_ipv6_client(client):
    data = client_ip(client, '2001:db8::1')
    assert data['IPv6'] == '2001:db8::1'
    assert data['IPv4'] is None

def test_xff_two_trusted_proxies(client, monkeypatch):
    """Cloudflare -> Traefik: the client is one entry left of the last proxy hop."""
    monkeypatch.setattr(app_module, 'TRUSTED_PROXY_COUNT', 2)
    data = client_ip(client, '8.8.8.8, 203.0.113.9, 198.51.100.1')
    assert data['IPv4'] == '203.0.113.9'

def test_xff_shorter_than_trusted_count(client, monkeypatch):
    monkeypatch.setattr(app_module, 'TRUSTED_PROXY_COUNT', 3)
    assert client_ip(client, '203.0.113.9')['IPv4'] == '203.0.113.9'

def test_xff_garbage_falls_back_to_socket_address(client):
    assert client_ip(client, 'not-an-ip')['IPv4'] == '127.0.0.1'

def test_xff_ignored_when_no_trusted_proxies(client, monkeypatch):
    monkeypatch.setattr(app_module, 'TRUSTED_PROXY_COUNT', 0)
    assert client_ip(client, '8.8.8.8')['IPv4'] == '127.0.0.1'

def test_xff_ipv4_mapped_ipv6_normalised(client):
    assert client_ip(client, '::ffff:203.0.113.9')['IPv4'] == '203.0.113.9'

def test_rate_limit_key_ignores_forged_xff():
    """A client must not get a fresh rate-limit bucket by forging the left of XFF."""
    with app.test_request_context('/', headers={'X-Forwarded-For': '1.1.1.1, 203.0.113.9'}):
        a = app_module.get_client_ip_for_limiter()
    with app.test_request_context('/', headers={'X-Forwarded-For': '2.2.2.2, 203.0.113.9'}):
        b = app_module.get_client_ip_for_limiter()
    assert a == b == '203.0.113.9'

# --- Reverse DNS ---

@pytest.fixture
def fresh_rdns_cache():
    app_module._rdns_cache.clear()
    yield
    app_module._rdns_cache.clear()

def test_iponly_and_pfsense_skip_reverse_dns(client, monkeypatch):
    def boom(ip):
        raise AssertionError("reverse DNS should not run for this endpoint")
    monkeypatch.setattr(app_module, 'lookup_hostname', boom)
    assert client.get('/iponly').status_code == 200
    assert client.get('/pfsense').status_code == 200

def test_json_still_resolves_hostname(client, monkeypatch):
    monkeypatch.setattr(app_module, 'lookup_hostname', lambda ip: 'host.example')
    assert client.get('/json').get_json()['HOSTNAME_IPv4'] == 'host.example'

def test_reverse_dns_timeout_and_cache(fresh_rdns_cache, monkeypatch):
    import time
    calls = []
    def slow_getfqdn(ip):
        calls.append(ip)
        time.sleep(0.3)
        return 'late.example'
    monkeypatch.setattr(app_module.socket, 'getfqdn', slow_getfqdn)
    monkeypatch.setattr(app_module, 'RDNS_TIMEOUT', 0.05)

    start = time.monotonic()
    assert app_module.lookup_hostname('203.0.113.9') == 'Hostname not found'
    assert time.monotonic() - start < 0.25
    # Second call is served from the cache, no new lookup
    assert app_module.lookup_hostname('203.0.113.9') == 'Hostname not found'
    assert calls == ['203.0.113.9']

def test_reverse_dns_success_is_cached(fresh_rdns_cache, monkeypatch):
    calls = []
    monkeypatch.setattr(app_module.socket, 'getfqdn', lambda ip: calls.append(ip) or 'ok.example')
    assert app_module.lookup_hostname('203.0.113.10') == 'ok.example'
    assert app_module.lookup_hostname('203.0.113.10') == 'ok.example'
    assert len(calls) == 1

# --- Theme markers used by the JS ---

def test_theme_markers(client, monkeypatch):
    monkeypatch.setenv('WIN98_DEFAULT', 'false')
    assert b'data-theme="standard"' in client.get('/').data
    assert b'data-theme="98"' in client.get('/98').data

def test_win98_default_root_is_98_theme(client, monkeypatch):
    """Regression: the JS keyed off "98" in the URL, which '/' does not contain."""
    monkeypatch.setenv('WIN98_DEFAULT', 'true')
    assert b'data-theme="98"' in client.get('/').data
    assert b'data-theme="standard"' in client.get('/standard').data

def test_theme_carries_base_domain_and_subdomain_flag(client, monkeypatch):
    body = client.get('/').data
    assert f'data-base-domain="{app_module.BASE_DOMAIN}"'.encode() in body
    assert b'data-version-subdomains="true"' in body
    monkeypatch.setenv('NO_IP_VERSION_SUBDOMAINS', 'true')
    assert b'data-version-subdomains="false"' in client.get('/').data
