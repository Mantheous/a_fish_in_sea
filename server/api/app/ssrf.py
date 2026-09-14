"""SSRF guard for server-side fetches of user-supplied feed URLs.

Both /api/ical (open proxy) and /v1/fetch/* (authenticated fetch) make
the server issue HTTP requests to URLs the user controls. Without host
validation the server becomes a proxy into loopback / LAN /
cloud-metadata addresses (e.g. http://169.254.169.254/ or
http://localhost:11434/).

Policy: http(s) only, no embedded credentials, and the host must
resolve solely to non-internal IPs. Loopback, link-local (cloud
metadata), RFC1918 LAN, multicast, reserved and wildcard addresses are
rejected. CGNAT 100.64/10 (Tailnet) is allowed so self-hosted Tailnet
feeds keep working. Every redirect hop is re-validated and bodies are
capped at 5MB.
"""

from __future__ import annotations

import ipaddress
import socket
import urllib.parse

import httpx

MAX_BYTES = 5 * 1024 * 1024
MAX_ICS_BYTES = MAX_BYTES  # alias used by the fetch snapshot cache
MAX_REDIRECTS = 3

_RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def assert_public_http_url(url: str) -> str:
    """Validate url and return it unchanged. Raises ValueError on policy
    violation (caller maps to HTTP 400 or a stored feed error)."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("Only http(s) feed urls supported")
    if parsed.username or parsed.password:
        raise ValueError("Credentials in feed URL are not allowed")
    host = parsed.hostname
    if not host:
        raise ValueError("Invalid feed URL")
    try:
        addrinfo = socket.getaddrinfo(host, parsed.port or 0)
    except socket.gaierror:
        raise ValueError(f"Could not resolve feed host: {host}")
    for _, _, _, _, sockaddr in addrinfo:
        try:
            ip = ipaddress.ip_address(sockaddr[0])
        except ValueError:
            raise ValueError(f"Could not resolve feed host: {host}")
        if (
            ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
            or any(ip in net for net in _RFC1918)
        ):
            raise ValueError("Feed host resolves to an internal address")
    return url


async def fetch_public_bytes(url: str, timeout: float = 30.0) -> tuple[bytes, str]:
    """Fetch url with per-hop SSRF validation. Returns (body, etag)."""
    current = url
    for _ in range(MAX_REDIRECTS + 1):
        assert_public_http_url(current)
        async with httpx.AsyncClient(
            timeout=timeout, follow_redirects=False
        ) as c:
            resp = await c.get(current)
        location = resp.headers.get("location")
        if resp.status_code in (301, 302, 303, 307, 308) and location:
            current = urllib.parse.urljoin(current, location)
            continue
        if resp.status_code >= 400:
            raise ValueError(f"Feed returned {resp.status_code}")
        if len(resp.content) > MAX_BYTES:
            raise ValueError("Feed too large (>5MB)")
        return resp.content, resp.headers.get("etag", "")
    raise ValueError("Too many redirects")
