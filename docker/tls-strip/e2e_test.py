#!/usr/bin/env python3
"""End-to-end check of the TLS-strip proxy from a simulated handset. Run in the VM.

Web cases run in a throwaway container on fou-nat's namespace: handset packets (from 10.55.0.250)
are FOU-encapsulated straight to the kernel's FOU port, so they enter fou0 and
meet the real iptables redirect, and replies are read off fou0 with a packet
socket. TCP sessions are built with upstream's test helper
(~/1xbts/docker/fou-nat/test_fou_tcp_http.py), but its relay client is not
used: fou-nat's TCP relay takes a single client, and that client is the PDSN.
Replies are also encapsulated toward the PDSN, which drops them because
10.55.0.250 has no packet session.

Mail cases read each configured listener's greeting from inside fou-nat.

    python3 ~/1xbts-femtocell/docker/tls-strip/e2e_test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

ONEXBTS_DIR = os.environ.get("ONEXBTS_DIR", os.path.expanduser("~/1xbts"))
REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG = os.path.join(REPO_DIR, "config", "tls-strip.local.env")
FOU_NAT = "1xbts-fou-nat"
WEB_IMAGE = "mitmproxy/mitmproxy:12.3.1"
FOU_LISTEN_PORT = 17010
GATEWAY_IP = "10.55.0.1"
SRC_IP = "10.55.0.250"

WEB_DRIVER = r'''
import contextlib, io, json, socket, sys

req = json.load(sys.stdin)
ns = {"__name__": "fou_tcp_http"}
exec(compile(req["helper"], "test_fou_tcp_http.py", "exec"), ns)
src_ip = req["src_ip"]


class InjectClient:
    def __init__(self, fou_port):
        self.fou = ("127.0.0.1", fou_port)
        self.tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # ETH_P_ALL: only an all-protocols tap sees packets leaving fou0.
        self.rx = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0003))
        self.rx.bind(("fou0", 0))
        self.rx.settimeout(1.0)

    def send_packet(self, packet):
        self.tx.sendto(packet, self.fou)

    def recv_packet(self):
        try:
            return self.rx.recv(65535)
        except socket.timeout:
            return b""


client = InjectClient(req["fou_port"])
build, parse, resolve = ns["build_tcp_packet"], ns["parse_tcp"], ns["resolve_target"]
for case in req["cases"]:
    captured = bytearray()
    request_line = ("GET %s " % case["path"]).encode()

    def build_with_path(*args, payload=b"", **kwargs):
        if payload.startswith(b"GET / HTTP/1.1"):
            payload = payload.replace(b"GET / ", request_line, 1)
        return build(*args, payload=payload, **kwargs)

    def parse_and_capture(packet):
        tcp = parse(packet)
        if tcp["dst_ip"] == src_ip and tcp["src_port"] == 80:
            captured.extend(tcp["tcp_payload"])
        return tcp

    ns["build_tcp_packet"] = build_with_path
    ns["parse_tcp"] = parse_and_capture
    dst_ip = case.get("dst_ip")
    ns["resolve_target"] = (lambda _host: dst_ip) if dst_ip else resolve
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            result = ns["run_http_session"](client, src_ip, case["host"], 80, 15.0, True)
    except Exception as err:
        result = {"ok": False, "reason": str(err)}
    head = b""
    if result.get("ok"):
        start = captured.find(b"HTTP/1.")
        head = captured[start:].split(b"\r\n\r\n", 1)[0]
    print(json.dumps({"ok": bool(result.get("ok")), "reason": result.get("reason"),
                      "head": head.decode("latin1")}), flush=True)
'''

MAIL_GREETING = """
import socket, sys
s = socket.create_connection(("%s", int(sys.argv[1])), 20)
s.settimeout(20)
print(s.recv(512).decode("latin1").splitlines()[0])
""" % GATEWAY_IP

WEB_CASES = [
    {"host": "example.com", "path": "/"},
    {"host": "httpforever.com", "path": "/"},
    {"host": "google.com", "path": "/"},
    {"host": "expired.badssl.com", "path": "/"},
    {"host": "speed.local.1xbts.org", "path": "/", "dst_ip": GATEWAY_IP},
]


def run(argv: list[str], stdin: str | None = None) -> str:
    proc = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()[-1:] or ["no output"]
        raise RuntimeError(f"{' '.join(argv[:4])} exited {proc.returncode}: {tail[0]}")
    return proc.stdout


def fou_nat(*cmd: str, stdin: str | None = None) -> str:
    return run(["docker", "exec", "-i", FOU_NAT, *cmd], stdin)


def netns_python(program: str, stdin: str) -> str:
    """Run Python in fou-nat's namespace. fou-nat's own python3 (3.11) can't
    parse the upstream helper, so borrow the web proxy's newer interpreter."""
    return run(
        ["docker", "run", "--rm", "-i", f"--network=container:{FOU_NAT}", "--entrypoint=python3",
         WEB_IMAGE, "-c", program],
        stdin,
    )


def gateway_exclusion_hits() -> int:
    out = fou_nat("iptables", "-t", "nat", "-L", "TLS_STRIP_PRE", "-n", "-v", "-x")
    for line in out.splitlines():
        fields = line.split()
        if len(fields) > 2 and fields[2] == "RETURN":
            return int(fields[0])
    raise RuntimeError("TLS_STRIP_PRE has no RETURN rule")


def mail_ports() -> list[str]:
    if not os.path.exists(CONFIG):
        return []
    with open(CONFIG) as f:
        for line in f:
            if line.startswith("MAIL_UPSTREAMS="):
                value = line.strip().split("=", 1)[1]
                return [e.split("=", 1)[0] for e in value.split(",") if "=" in e]
    return []


def check(name: str, ok: bool, detail: str) -> int:
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
    return 0 if ok else 1


def web_checks() -> int:
    helper = os.path.join(ONEXBTS_DIR, "docker", "fou-nat", "test_fou_tcp_http.py")
    with open(helper) as f:
        request = {"helper": f.read(), "cases": WEB_CASES, "src_ip": SRC_IP, "fou_port": FOU_LISTEN_PORT}

    before = gateway_exclusion_hits()
    out = netns_python(WEB_DRIVER, json.dumps(request))
    after = gateway_exclusion_hits()

    replies = {}
    for case, line in zip(WEB_CASES, out.splitlines()):
        reply = json.loads(line)
        status, _, headers = reply["head"].partition("\r\n")
        replies[case["host"]] = (status if reply["ok"] else f"FAILED ({reply['reason']})", headers.lower())

    failures = 0
    status, _ = replies["example.com"]
    failures += check("upgraded to HTTPS upstream", status.endswith(" 200 OK"), status)

    status, _ = replies["httpforever.com"]
    failures += check("plain HTTP when 443 has no working HTTPS", " 200 " in status, status)

    status, headers = replies["google.com"]
    location = next((h for h in headers.splitlines() if h.startswith("location:")), "")
    failures += check(
        "redirect Location rewritten to http://",
        " 30" in status and location.startswith("location: http://www.google.com/"),
        f"{status} | {location}",
    )
    hsts = "strict-transport-security" in headers
    failures += check("HSTS dropped", not hsts, "present" if hsts else "absent")

    status, _ = replies["expired.badssl.com"]
    failures += check("expired certificate refused, not downgraded", " 502 " in status, status)

    status, _ = replies["speed.local.1xbts.org"]
    failures += check(
        "gateway traffic bypasses the proxy",
        after > before and not status.startswith("FAILED"),
        f"{status} (exclusion hits {before} -> {after})",
    )
    return failures


def mail_checks() -> int:
    failures = 0
    for port in mail_ports():
        try:
            line = fou_nat("python3", "-", port, stdin=MAIL_GREETING).strip()
        except RuntimeError as err:
            line = f"error: {err}"
        failures += check(
            f"mail listener {GATEWAY_IP}:{port}", line.startswith(("* OK", "+OK", "220")), line
        )
    return failures


def main() -> int:
    failures = web_checks() + mail_checks()
    print(f"\n{'all checks passed' if not failures else f'{failures} check(s) failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
