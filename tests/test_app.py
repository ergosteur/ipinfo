import pytest
import sys
import os

# Add the parent directory to sys.path to find app.py
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

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
