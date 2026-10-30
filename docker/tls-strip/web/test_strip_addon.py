"""Run: uv run --python 3.12 --with mitmproxy==12.3.1 --with pytest --with pytest-asyncio \
    pytest -q docker/tls-strip/web"""

import asyncio
import gzip
import ssl

import pytest
from mitmproxy.test import taddons, tflow, tutils

import strip_addon
from strip_addon import HttpsProbe, StripTLS, rewrite_urls, should_upgrade, strip_secure_flag


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def fake_connect(results: dict[str, bool], calls: list[str]):
    async def connect(host: str, port: int, timeout: float) -> None:
        calls.append(host)
        await asyncio.sleep(0)
        if not results.get(host, False):
            raise ConnectionRefusedError(host)

    return connect


def plain_request_flow(host_header: str = "example.com", port: int = 80, **headers):
    req = tutils.treq(
        scheme=b"http",
        host=b"93.184.215.14",
        port=port,
        authority=b"",
        path=b"/page?q=1",
        headers=((b"host", host_header.encode()),)
        + tuple((k.replace("_", "-").encode(), v.encode()) for k, v in headers.items()),
    )
    return tflow.tflow(req=req)


def response_flow(body: bytes, content_type: str = "text/html; charset=utf-8", **headers):
    flow = tflow.tflow(resp=True)
    flow.response.headers.clear()
    flow.response.content = body
    flow.response.headers["content-type"] = content_type
    for name, value in headers.items():
        flow.response.headers[name.replace("_", "-")] = value
    return flow


@pytest.fixture
def addon():
    a = StripTLS()
    with taddons.context(a) as tctx:
        tctx.configure(a, strip_passthrough_hosts="legacy.example, intranet.test")
        yield a


class TestRewriteUrls:
    def test_basic_and_default_port(self):
        assert rewrite_urls(b'<a href="https://a.example/x">') == b'<a href="http://a.example/x">'
        assert rewrite_urls(b"https://a.example:443/x") == b"http://a.example/x"
        assert rewrite_urls(b"HTTPS://A.Example") == b"http://A.Example"

    def test_json_escaped(self):
        assert rewrite_urls(b'{"u":"https:\\/\\/a.example\\/x"}') == b'{"u":"http:\\/\\/a.example\\/x"}'

    def test_other_ports_untouched(self):
        for url in (b"https://a.example:8443/x", b"https://a.example:4430"):
            assert rewrite_urls(url) == url

    def test_non_urls_untouched(self):
        for text in (b"https%3A%2F%2Fa.example", b"https:a", b"https://", b"https://-bad"):
            assert rewrite_urls(text) == text


def test_strip_secure_flag():
    assert strip_secure_flag("a=1; Path=/; Secure; HttpOnly") == "a=1; Path=/; HttpOnly"
    assert strip_secure_flag("a=1; secure") == "a=1"
    assert strip_secure_flag("secure=1; Path=/") == "secure=1; Path=/"
    assert strip_secure_flag("a=1; SecureX=2") == "a=1; SecureX=2"


@pytest.mark.parametrize(
    "host,port,expected",
    [
        ("example.com", 80, True),
        ("example.com", 8080, False),
        ("speed", 80, False),
        ("192.168.1.10", 80, False),
        ("10.55.0.1", 80, False),
        ("1.1.1.1", 80, True),
        ("legacy.example", 80, False),
        ("www.legacy.example", 80, False),
        ("notlegacy.example", 80, True),
        ("_dmarc.example.com", 80, True),
        ("", 80, False),
        ("a..example", 80, False),
        ("bad host.example", 80, False),
        ("evil.example\r\nx", 80, False),
        ("evil.example\n", 80, False),
        ("-lead.example", 80, False),
    ],
)
def test_should_upgrade(host, port, expected):
    assert should_upgrade(host, port, ("legacy.example",)) is expected


class TestProbe:
    async def test_caches_both_outcomes_with_ttl(self):
        calls: list[str] = []
        clock = FakeClock()
        probe = HttpsProbe(
            timeout=1, ok_ttl=100, fail_ttl=10,
            connect=fake_connect({"up.example": True}, calls), clock=clock,
        )
        assert await probe.reachable("up.example") is True
        assert await probe.reachable("down.example") is False
        assert await probe.reachable("up.example") is True
        assert await probe.reachable("down.example") is False
        assert calls == ["up.example", "down.example"]

        clock.now = 11
        assert await probe.reachable("down.example") is False
        assert await probe.reachable("up.example") is True
        assert calls == ["up.example", "down.example", "down.example"]

    async def test_concurrent_lookups_share_one_probe(self):
        calls: list[str] = []
        probe = HttpsProbe(timeout=1, connect=fake_connect({"a.example": True}, calls))
        results = await asyncio.gather(*(probe.reachable("a.example") for _ in range(5)))
        assert results == [True] * 5
        assert calls == ["a.example"]

    @pytest.mark.parametrize(
        "error,expected",
        [
            (asyncio.TimeoutError(), False),
            (ConnectionResetError(), False),
            (ssl.SSLEOFError(), False),
            (ssl.SSLError("wrong version number"), False),
            (ssl.SSLCertVerificationError("certificate has expired"), True),
        ],
    )
    async def test_handshake_errors(self, error, expected):
        async def fail(host, port, timeout):
            raise error

        assert await HttpsProbe(timeout=1, connect=fail).reachable("h.example") is expected

    async def test_evicts_oldest(self):
        probe = HttpsProbe(timeout=1, max_entries=2, connect=fake_connect({}, []))
        for host in ("a.example", "b.example", "c.example"):
            await probe.reachable(host)
        assert list(probe._cache) == ["b.example", "c.example"]


class TestRequest:
    async def test_upgrades_reachable_host(self, addon):
        addon.probe = HttpsProbe(timeout=1, connect=fake_connect({"example.com": True}, []))
        flow = plain_request_flow(
            "Example.COM", origin="http://example.com", referer="http://example.com/prev"
        )
        await addon.request(flow)
        req = flow.request
        assert (req.scheme, req.host, req.port) == ("https", "example.com", 443)
        assert req.headers["host"] == "example.com"
        assert req.headers["origin"] == "https://example.com"
        assert req.headers["referer"] == "https://example.com/prev"
        assert req.path == "/page?q=1"
        assert flow.metadata["strip_upgraded"] is True

    async def test_cross_origin_referer_untouched(self, addon):
        addon.probe = HttpsProbe(timeout=1, connect=fake_connect({"example.com": True}, []))
        flow = plain_request_flow(referer="http://other.example/")
        await addon.request(flow)
        assert flow.request.headers["referer"] == "http://other.example/"

    async def test_unreachable_host_stays_plain(self, addon):
        addon.probe = HttpsProbe(timeout=1, connect=fake_connect({}, []))
        flow = plain_request_flow()
        await addon.request(flow)
        assert (flow.request.scheme, flow.request.port) == ("http", 80)
        assert "strip_upgraded" not in flow.metadata

    async def test_passthrough_never_probed(self, addon):
        calls: list[str] = []
        addon.probe = HttpsProbe(timeout=1, connect=fake_connect({"intranet.test": True}, calls))
        flow = plain_request_flow("wiki.intranet.test")
        await addon.request(flow)
        assert flow.request.scheme == "http"
        assert calls == []


class TestResponse:
    def test_headers(self, addon):
        flow = response_flow(
            b"",
            location="https://example.com/next",
            refresh="0; url=https://example.com/",
            strict_transport_security="max-age=31536000",
            content_security_policy="upgrade-insecure-requests",
        )
        flow.response.headers.add("set-cookie", "a=1; Secure; HttpOnly")
        flow.response.headers.add("set-cookie", "b=2; Path=/; secure")
        addon.responseheaders(flow)
        h = flow.response.headers
        assert h["location"] == "http://example.com/next"
        assert h["refresh"] == "0; url=http://example.com/"
        assert "strict-transport-security" not in h
        assert "content-security-policy" not in h
        assert h.get_all("set-cookie") == ["a=1; HttpOnly", "b=2; Path=/"]

    @pytest.mark.parametrize(
        "upgraded,location,learned",
        [
            (False, "https://example.com/next", True),
            (False, "https://example.com:443", True),
            (False, "https://other.example/", False),
            (False, "https://example.com.evil.test/", False),
            (True, "https://example.com/next", False),
        ],
    )
    async def test_https_redirect_teaches_probe(self, addon, upgraded, location, learned):
        addon.probe = HttpsProbe(timeout=1, connect=fake_connect({}, []))
        assert await addon.probe.reachable("example.com") is False
        flow = plain_request_flow()
        if upgraded:
            flow.metadata["strip_upgraded"] = True
        flow.response = tutils.tresp(status_code=301, headers=((b"location", location.encode()),))
        addon.responseheaders(flow)
        assert flow.response.headers["location"].startswith("http://")
        assert await addon.probe.reachable("example.com") is learned

    def test_html_body_rewritten_and_reencoded(self, addon):
        html = b'<a href="https://example.com/">x</a><img src="https://cdn.example/i.png">'
        flow = response_flow(html)
        flow.response.encode("gzip")
        addon.responseheaders(flow)
        assert not flow.response.stream
        addon.response(flow)
        assert flow.response.headers["content-encoding"] == "gzip"
        assert gzip.decompress(flow.response.raw_content) == (
            b'<a href="http://example.com/">x</a><img src="http://cdn.example/i.png">'
        )

    def test_binary_is_streamed_untouched(self, addon):
        flow = response_flow(b"https://example.com", content_type="image/png")
        addon.responseheaders(flow)
        assert flow.response.stream
        addon.response(flow)
        assert flow.response.content == b"https://example.com"

    def test_oversized_text_is_streamed(self, addon):
        flow = response_flow(b"x", content_length=str(9 * 1024 * 1024))
        addon.responseheaders(flow)
        assert flow.response.stream


@pytest.mark.parametrize(
    "upgraded,message,still_https",
    [
        (True, "server closed connection", False),
        (True, "Certificate verify failed: certificate has expired", True),
        (False, "server closed connection", True),
    ],
)
async def test_failed_upgrade_falls_back_next_time(addon, upgraded, message, still_https):
    addon.probe = HttpsProbe(timeout=1, connect=fake_connect({"example.com": True}, []))
    assert await addon.probe.reachable("example.com") is True
    flow = tflow.tflow(err=True)
    flow.request.host = "example.com"
    flow.request.headers["host"] = "example.com"
    flow.error.msg = message
    if upgraded:
        flow.metadata["strip_upgraded"] = True
    addon.error(flow)
    assert await addon.probe.reachable("example.com") is still_https


def test_module_exports_addon():
    assert any(isinstance(a, StripTLS) for a in strip_addon.addons)
