"""The iOS profile responder speaks HTTPS with the DoT certificate.

Runs the real lib/ios-http.py the way systemd does (Accept=yes: the client
socket is its stdin/stdout): a TLS client gets the profile, a plain HTTP
request is redirected to https://<same host>/<same path>, and only when no
certificate exists yet is the profile served over plain HTTP. Every answer
requires the Host header to name the current DoT domain: the domain is the
secret that admits phones at dot-gate, so asking the bare IP yields 404.
"""
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "lib" / "ios-http.py"
PROFILE = b"<plist>profile</plist>\n"


@unittest.skipUnless(shutil.which("openssl"), "openssl is required to make a test certificate")
class IosHttpsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        cls.www = d / "www"
        cls.www.mkdir()
        (cls.www / "ios-dot.mobileconfig").write_bytes(PROFILE)
        (cls.www / "index.html").write_text("<a href=/ios-dot.mobileconfig>x</a>")
        cls.domain_file = d / "domain"
        cls.domain_file.write_text("ABC.dns.example.net\n")
        cls.cert, cls.key = d / "fullchain.pem", d / "privkey.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=abc.dns.example.net", "-keyout", str(cls.key), "-out", str(cls.cert)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def serve_once(self, cert, key, domain_file=None):
        """Start ios-http.py on one accepted connection; return the client socket."""
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        conn, _ = listener.accept()
        listener.close()
        env = dict(os.environ, WWW_DIR=str(self.www), IOS_TLS_CERT=str(cert), IOS_TLS_KEY=str(key),
                   IOS_DOMAIN_FILE=str(domain_file or self.domain_file))
        proc = subprocess.Popen([sys.executable, str(SCRIPT)], stdin=conn, stdout=conn, env=env)
        conn.close()
        self.addCleanup(proc.wait, 10)
        return client

    @staticmethod
    def exchange(sock, request):
        sock.sendall(request)
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                return data
            data += chunk

    def test_tls_client_gets_the_profile(self):
        raw = self.serve_once(self.cert, self.key)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with ctx.wrap_socket(raw, server_hostname="abc.dns.example.net") as tls:
            self.assertGreaterEqual(tls.version(), "TLSv1.2")
            reply = self.exchange(tls, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: abc.dns.example.net:8111\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 200 OK"), reply[:80])
        self.assertIn(b"application/x-apple-aspen-config", reply)
        self.assertTrue(reply.endswith(PROFILE))

    def test_plain_http_is_redirected_to_https(self):
        raw = self.serve_once(self.cert, self.key)
        with raw:
            reply = self.exchange(raw, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: abc.dns.example.net:8111\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 301"), reply[:80])
        self.assertIn(b"Location: https://abc.dns.example.net:8111/ios-dot.mobileconfig\r\n", reply)
        self.assertNotIn(PROFILE, reply, "the profile must never be sent over plain HTTP when TLS is available")

    def test_other_hosts_get_404_and_are_never_reflected(self):
        for host in (b"evil.example", b"a\"b<c>", b"203.0.113.5:8111", b"127.0.0.1", b"",
                     b"abc.dns.example.net.evil.example", b"xabc.dns.example.net"):
            with self.subTest(host=host):
                raw = self.serve_once(self.cert, self.key)
                with raw:
                    reply = self.exchange(raw, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: " + host + b"\r\nX: y\r\n\r\n")
                self.assertTrue(reply.startswith(b"HTTP/1.1 404"), reply[:80])
                self.assertNotIn(b"Location:", reply)
                self.assertNotIn(PROFILE, reply)

    def test_tls_client_with_wrong_host_gets_404(self):
        raw = self.serve_once(self.cert, self.key)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with ctx.wrap_socket(raw, server_hostname="abc.dns.example.net") as tls:
            reply = self.exchange(tls, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: 203.0.113.5:8111\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 404"), reply[:80])
        self.assertNotIn(PROFILE, reply)

    def test_host_matching_is_case_insensitive_and_ignores_port_and_dot(self):
        raw = self.serve_once(self.cert, self.key)
        with raw:
            reply = self.exchange(raw, b"GET /index.html HTTP/1.1\r\nHost: abc.DNS.example.net.\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 301"), reply[:80])

    def test_unknown_domain_serves_nothing(self):
        missing = Path(self.tmp.name) / "no-domain"
        raw = self.serve_once(self.cert, self.key, domain_file=missing)
        with raw:
            reply = self.exchange(raw, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: abc.dns.example.net:8111\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 404"), reply[:80])
        self.assertNotIn(PROFILE, reply)

    def test_unit_runs_unprivileged_and_capped(self):
        services = (ROOT / "lib" / "services.sh").read_text()
        unit = services.split("simcard-dns-ios-profile@.service <<EOF")[1].split("EOF")[0]
        self.assertIn("User=mosdns", unit)
        self.assertNotIn("User=root", unit)
        for option in ("NoNewPrivileges=true", "ProtectSystem=strict", "ProtectHome=true", "CapabilityBoundingSet="):
            self.assertIn(option, unit)
        self.assertIn("IOS_DOMAIN_FILE=", unit)
        sock = services.split("simcard-dns-ios-profile.socket <<EOF")[1].split("EOF")[0]
        self.assertIn("MaxConnectionsPerSource=", sock)
        self.assertIn("MaxConnections=", sock)

    def test_without_a_certificate_plain_http_still_works(self):
        missing = Path(self.tmp.name) / "missing.pem"
        raw = self.serve_once(missing, missing)
        with raw:
            reply = self.exchange(raw, b"GET /ios-dot.mobileconfig HTTP/1.1\r\nHost: abc.dns.example.net:8111\r\n\r\n")
        self.assertTrue(reply.startswith(b"HTTP/1.1 200 OK"), reply[:80])
        self.assertTrue(reply.endswith(PROFILE))

    def test_unknown_path_and_method(self):
        raw = self.serve_once(self.cert, self.key)
        with raw:
            self.assertTrue(self.exchange(raw, b"GET /etc/passwd HTTP/1.1\r\n\r\n").startswith(b"HTTP/1.1 404"))
        raw = self.serve_once(self.cert, self.key)
        with raw:
            self.assertTrue(self.exchange(raw, b"POST / HTTP/1.1\r\n\r\n").startswith(b"HTTP/1.1 400"))

    def test_urls_use_https(self):
        services = (ROOT / "lib" / "services.sh").read_text()
        self.assertIn('profile_url="https://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig"', services)
        bot = (ROOT / "lib" / "tgbot.py").read_text()
        self.assertNotIn('"http://%s:8111', bot)
        self.assertIn('"https://%s:8111/ios-dot.mobileconfig"', bot)


if __name__ == "__main__":
    unittest.main()
