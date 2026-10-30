"""mitmproxy addon: plain HTTP to the handsets, verified HTTPS to the internet.

Loaded by mitmdump in transparent mode behind an iptables REDIRECT of handset
TCP 80. Each request is sent upstream over HTTPS when the host answers HTTP
over TLS on 443, and every https:// URL in the response is rewritten to
http:// so the handset never starts a TLS handshake itself.

Upstream certificates are always verified (mitmproxy's default). A host that
presents a certificate which fails verification gets mitmproxy's 502 error
page; it is never silently downgraded to plain HTTP. Only a host with no
working HTTPS on 443 at all (closed, reset, no handshake, no HTTP answer) is
fetched over HTTP.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import os
import re
import ssl
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable

import certifi
from mitmproxy import ctx, http

log = logging.getLogger(__name__)

REWRITABLE_TYPES = frozenset(
    {
        "text/html",
        "application/xhtml+xml",
        "text/css",
        "text/javascript",
        "application/javascript",
        "application/x-javascript",
        "application/ecmascript",
        "text/vnd.wap.wml",
        "text/xml",
        "application/xml",
        "application/rss+xml",
        "application/atom+xml",
        "application/json",
    }
)

URL_HEADERS = ("location", "content-location", "refresh", "link")
REDIRECTS = frozenset({301, 302, 303, 307, 308})

# Headers that only make sense over TLS, or that would make an old browser
# refuse the http:// URLs this addon hands it.
DROPPED_HEADERS = (
    "strict-transport-security",
    "content-security-policy",
    "content-security-policy-report-only",
    "expect-ct",
    "public-key-pins",
    "public-key-pins-report-only",
    "alt-svc",
)

# https://host or https://host:443, plain or JSON-escaped (https:\/\/host).
# A URL with any other explicit port is left alone: the handset would dial that
# port directly, and only port 80 is redirected through this proxy.
_HTTPS_URL = re.compile(
    rb"https:(//|\\/\\/)([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)(?::443)?(?![a-z0-9.:-])",
    re.IGNORECASE,
)
_SECURE_ATTR = re.compile(r";\s*secure\s*(?=;|$)", re.IGNORECASE)
# At least two labels: single-label names (speed, intranet hosts) stay on HTTP.
_HOSTNAME = re.compile(r"(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{1,63}")


def rewrite_urls(data: bytes) -> bytes:
    return _HTTPS_URL.sub(rb"http:\1\2", data)


def rewrite_url_text(value: str) -> str:
    return rewrite_urls(value.encode("utf-8", "surrogateescape")).decode(
        "utf-8", "surrogateescape"
    )


def strip_secure_flag(set_cookie: str) -> str:
    return _SECURE_ATTR.sub("", set_cookie)


def redirects_to_https_self(location: str, host: str) -> bool:
    location = location.strip().lower()
    return any(
        location == base or location.startswith(base + "/")
        for base in (f"https://{host}", f"https://{host}:443")
    )


def media_type(content_type: str | None) -> str:
    return (content_type or "").split(";", 1)[0].strip().lower()


def parse_host_list(value: str) -> tuple[str, ...]:
    return tuple(
        h.strip().lower().strip(".") for h in value.split(",") if h.strip().strip(".")
    )


def should_upgrade(host: str, port: int, passthrough: tuple[str, ...]) -> bool:
    """Whether a plain-HTTP request for host:port should go upstream over HTTPS."""
    if port != 80 or not host:
        return False
    try:
        return ipaddress.ip_address(host).is_global
    except ValueError:
        pass
    if not _HOSTNAME.fullmatch(host):
        return False
    return not any(host == p or host.endswith("." + p) for p in passthrough)


_TLS_CONTEXT = ssl.create_default_context(cafile=certifi.where())


async def _https_responds(host: str, port: int, timeout: float) -> None:
    """Raise unless host answers an HTTP request over verified TLS within timeout."""

    async def attempt() -> None:
        reader, writer = await asyncio.open_connection(
            host, port, ssl=_TLS_CONTEXT, server_hostname=host
        )
        try:
            writer.write(
                f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode("ascii")
            )
            await writer.drain()
            status = await reader.readline()
        finally:
            # No TLS close_notify exchange: a server that never answers it would
            # stall the probe past its timeout.
            writer.transport.abort()
        if not status.startswith(b"HTTP/"):
            raise ConnectionError("no HTTP response over TLS")

    await asyncio.wait_for(attempt(), timeout)


class HttpsProbe:
    """Caches whether a host should be fetched over HTTPS.

    Yes when the host answers HTTP over verified TLS on 443, and also when it
    presents a certificate that fails verification, so the request is refused
    rather than downgraded. No when there is no working HTTPS there at all.
    """

    def __init__(
        self,
        timeout: float,
        ok_ttl: float = 3600.0,
        fail_ttl: float = 600.0,
        max_entries: int = 4096,
        connect: Callable[[str, int, float], Awaitable[None]] = _https_responds,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.timeout = timeout
        self.ok_ttl = ok_ttl
        self.fail_ttl = fail_ttl
        self.max_entries = max_entries
        self._connect = connect
        self._clock = clock
        self._cache: OrderedDict[str, tuple[bool, float]] = OrderedDict()
        self._inflight: dict[str, asyncio.Future[bool]] = {}

    async def reachable(self, host: str) -> bool:
        cached = self._cache.get(host)
        if cached is not None:
            ok, expires = cached
            if self._clock() < expires:
                self._cache.move_to_end(host)
                return ok
            del self._cache[host]

        pending = self._inflight.get(host)
        if pending is not None:
            return await pending

        future: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self._inflight[host] = future
        try:
            ok = await self._probe(host)
            self.remember(host, ok)
            future.set_result(ok)
            return ok
        finally:
            del self._inflight[host]
            if not future.done():
                future.cancel()

    async def _probe(self, host: str) -> bool:
        try:
            await self._connect(host, 443, self.timeout)
        except ssl.SSLCertVerificationError:
            return True
        except (OSError, asyncio.TimeoutError):
            return False
        return True

    def remember(self, host: str, ok: bool) -> None:
        ttl = self.ok_ttl if ok else self.fail_ttl
        self._cache[host] = (ok, self._clock() + ttl)
        self._cache.move_to_end(host)
        while len(self._cache) > self.max_entries:
            self._cache.popitem(last=False)


class StripTLS:
    def __init__(self) -> None:
        self.passthrough: tuple[str, ...] = ()
        self.probe: HttpsProbe | None = None

    def load(self, loader) -> None:
        loader.add_option(
            "strip_passthrough_hosts",
            str,
            os.environ.get("STRIP_PASSTHROUGH_HOSTS", ""),
            "Comma-separated hosts (and their subdomains) always fetched over plain HTTP.",
        )
        loader.add_option(
            "strip_probe_timeout",
            float,
            float(os.environ.get("STRIP_PROBE_TIMEOUT") or 4),
            "Seconds to wait for a host to answer HTTPS on port 443 before staying on HTTP.",
        )
        loader.add_option(
            "strip_max_rewrite_bytes",
            int,
            int(os.environ.get("STRIP_MAX_REWRITE_BYTES") or 8 * 1024 * 1024),
            "Larger bodies are streamed through without URL rewriting.",
        )

    def configure(self, updated: set[str]) -> None:
        if "strip_passthrough_hosts" in updated:
            self.passthrough = parse_host_list(ctx.options.strip_passthrough_hosts)
        if self.probe is None or "strip_probe_timeout" in updated:
            self.probe = HttpsProbe(timeout=ctx.options.strip_probe_timeout)

    async def request(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        if req.scheme != "http":
            return
        host = req.pretty_host.lower().rstrip(".")
        if not should_upgrade(host, req.port, self.passthrough):
            return
        assert self.probe is not None
        if not await self.probe.reachable(host):
            log.info("%s: no working HTTPS on port 443, fetching over plain HTTP", host)
            return

        plain_origin = f"http://{host}"
        req.scheme = "https"
        req.host = host
        req.port = 443
        req.host_header = host
        for name in ("origin", "referer"):
            value = req.headers.get(name)
            if value and (value == plain_origin or value.startswith(plain_origin + "/")):
                req.headers[name] = "https://" + value[len("http://") :]
        flow.metadata["strip_upgraded"] = True

    def responseheaders(self, flow: http.HTTPFlow) -> None:
        resp = flow.response
        assert resp is not None
        headers = resp.headers
        if not flow.metadata.get("strip_upgraded") and resp.status_code in REDIRECTS:
            # A plain-HTTP fetch that redirects to HTTPS on the same host means
            # the probe missed (e.g. a slow first answer). Without this the
            # rewritten redirect would loop until the negative cache expires.
            host = flow.request.pretty_host.lower().rstrip(".")
            if (
                self.probe is not None
                and redirects_to_https_self(headers.get("location", ""), host)
                and should_upgrade(host, flow.request.port, self.passthrough)
            ):
                self.probe.remember(host, True)
        for name in DROPPED_HEADERS:
            if name in headers:
                del headers[name]
        for name in URL_HEADERS:
            values = headers.get_all(name)
            if values:
                headers.set_all(name, [rewrite_url_text(v) for v in values])
        cookies = headers.get_all("set-cookie")
        if cookies:
            headers.set_all("set-cookie", [strip_secure_flag(c) for c in cookies])

        if media_type(headers.get("content-type")) not in REWRITABLE_TYPES:
            resp.stream = True
            return
        length = headers.get("content-length")
        if length and length.isdigit() and int(length) > ctx.options.strip_max_rewrite_bytes:
            resp.stream = True

    def response(self, flow: http.HTTPFlow) -> None:
        resp = flow.response
        assert resp is not None
        if resp.stream or media_type(resp.headers.get("content-type")) not in REWRITABLE_TYPES:
            return
        body = resp.get_content(strict=False)
        if not body or len(body) > ctx.options.strip_max_rewrite_bytes:
            return
        rewritten = rewrite_urls(body)
        if rewritten != body:
            resp.content = rewritten

    def error(self, flow: http.HTTPFlow) -> None:
        if flow.error is None:
            return
        host = flow.request.pretty_host.lower().rstrip(".")
        log.warning("%s: %s", host, flow.error.msg)
        # A host can pass the probe and still drop real requests (neverssl.com
        # answers nothing over HTTPS). Send the next request over plain HTTP,
        # unless the failure was the certificate: that is never downgraded.
        if (
            flow.metadata.get("strip_upgraded")
            and flow.response is None
            and "certificate" not in flow.error.msg.lower()
            and self.probe is not None
        ):
            self.probe.remember(host, False)


addons = [StripTLS()]
