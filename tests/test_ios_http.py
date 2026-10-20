"""The iOS profile responder speaks HTTPS with the DoT certificate.

Runs the real lib/ios-http.py the way systemd does (Accept=yes: the client
socket is its stdin/stdout): a TLS client gets the profile, a plain HTTP
request is redirected to https://<same host>/<same path>, and only when no
certificate exists yet is the profile served over plain HTTP.
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
        cls.cert, cls.key = d / "fullchain.pem", d / "privkey.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=abc.dns.example.net", "-keyout", str(cls.key), "-out", str(cls.cert)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def serve_once(self, cert, key):
        """Start ios-http.py on one accepted connection; return the client socket."""
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        conn, _ = listener.accept()
        listener.close()
        env = dict(os.environ, WWW_DIR=str(self.www), IOS_TLS_CERT=str(cert), IOS_TLS_KEY=str(key))
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

    def test_suspicious_host_is_not_reflected(self):
        raw = self.serve_once(self.cert, self.key)
        with raw:
            reply = self.exchange(raw, b"GET / HTTP/1.1\r\nHost: evil.example\r\nX: y\r\n\r\n")
        self.assertIn(b"Location: https://evil.example/", reply)
        raw = self.serve_once(self.cert, self.key)
        with raw:
            reply = self.exchange(raw, b"GET / HTTP/1.1\r\nHost: a\"b<c>\r\n\r\n")
        self.assertNotIn(b"Location:", reply)

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
