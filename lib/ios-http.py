#!/usr/bin/env python3
"""
Tiny inetd-style responder for the iOS DoT profile.

Invoked once per connection by systemd socket activation (Accept=yes), with the
client socket wired to stdin/stdout. Serves a couple of static files from
WWW_DIR. Zero processes when idle.

HTTPS: the DoT certificate (the *.dns.<zone> wildcard, or the own-domain
certificate) also covers the profile URL, so a TLS ClientHello is answered with
TLS. The profile names the DoT domain and points the phone at this resolver, so
plain HTTP would leak the name and let anyone on the path swap the profile:
a plain request is redirected to https://<same host>/<same path> instead. Only
when no certificate exists yet is the profile served over plain HTTP.

The DoT domain is a secret: it is random, kept out of certificate transparency
by the wildcard certificate, and dot-gate admits only connections that name
it. So this responder answers only requests whose Host header already names
the current domain; a scanner asking the bare IP gets 404 and learns nothing.

Runs unprivileged (the mosdns user can read the certificate and the domain
file) under a systemd sandbox; see write_ios_profile_units in services.sh.
"""
import os
import signal
import socket
import ssl
import sys

WWW_DIR = os.environ.get("WWW_DIR", "/opt/simcard-dns/www")
TLS_CERT = os.environ.get("IOS_TLS_CERT", "/etc/mosdns/certs/fullchain.pem")
TLS_KEY = os.environ.get("IOS_TLS_KEY", "/etc/mosdns/certs/privkey.pem")
DOMAIN_FILES = [x for x in os.environ.get(
    "IOS_DOMAIN_FILE", "/opt/simcard-dns/etc/.domain:/etc/mosdns/.domain").split(":") if x]

ROUTES = {
    "/ios-dot.mobileconfig": ("ios-dot.mobileconfig", "application/x-apple-aspen-config"),
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
}


def write(out, status, ctype, body, extra=""):
    head = (
        "HTTP/1.1 %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "%s"
        "Connection: close\r\n"
        "\r\n" % (status, ctype, len(body), extra)
    ).encode("ascii")
    out.write(head)
    out.write(body)
    out.flush()


def read_request(inp):
    """(method, path, host) from the request line and headers."""
    line = inp.readline(8192).decode("latin1", "replace")
    host = ""
    for _ in range(64):
        header = inp.readline(8192).decode("latin1", "replace")
        if header in ("\r\n", "\n", ""):
            break
        name, _, value = header.partition(":")
        if name.strip().lower() == "host":
            host = value.strip()
    parts = line.split()
    if len(parts) < 2:
        return "", "", host
    return parts[0], parts[1].split("?", 1)[0], host


def current_domain():
    """The DoT domain from the first readable domain file ("" when unknown)."""
    for path in DOMAIN_FILES:
        try:
            with open(path, encoding="utf-8") as f:
                value = f.read().strip().lower().rstrip(".")
        except OSError:
            continue
        if value:
            return value
    return ""


def host_matches(host, domain):
    """True when the Host header (optionally with :port) names `domain`."""
    if not host or not domain:
        return False
    name = host.strip().lower()
    if name.startswith("["):
        return False
    name = name.rsplit(":", 1)[0] if name.count(":") == 1 else name
    return name.rstrip(".") == domain


def serve(inp, out, tls, tls_available):
    method, path, host = read_request(inp)
    if method != "GET":
        write(out, "400 Bad Request", "text/plain", b"bad request\n")
        return
    route = ROUTES.get(path)
    # Fail closed: without the current domain (file unreadable) nothing is
    # served either, rather than handing the profile to whoever asks.
    if not route or not host_matches(host, current_domain()):
        write(out, "404 Not Found", "text/plain", b"not found\n")
        return
    if not tls and tls_available and all(c.isalnum() or c in ".-:" for c in host):
        location = "https://%s%s" % (host, path)
        write(out, "301 Moved Permanently", "text/plain", b"use https\n", "Location: %s\r\n" % location)
        return
    filename, ctype = route
    try:
        with open(os.path.join(WWW_DIR, filename), "rb") as f:
            body = f.read()
    except OSError:
        write(out, "404 Not Found", "text/plain", b"not found\n")
        return
    write(out, "200 OK", ctype, body)


def tls_context():
    if not (os.path.isfile(TLS_CERT) and os.path.isfile(TLS_KEY)):
        return None
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        return ctx
    except (OSError, ssl.SSLError):
        return None


def main():
    # Never let a stalled/half-open connection linger as a live process.
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(0))
    signal.alarm(10)

    ctx = tls_context()
    conn = socket.socket(fileno=os.dup(sys.stdin.fileno()))
    first = conn.recv(1, socket.MSG_PEEK)
    if first == b"\x16" and ctx is not None:  # TLS handshake record
        tls = ctx.wrap_socket(conn, server_side=True)
        stream = tls.makefile("rwb")
        serve(stream, stream, True, True)
        stream.close()
        tls.close()
        return
    serve(sys.stdin.buffer, sys.stdout.buffer, False, ctx is not None)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
