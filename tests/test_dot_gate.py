import asyncio
import importlib.util
import socket
import ssl
import tempfile
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dot_gate", root / "lib" / "dot-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def client_hello(sni):
    """A real TLS ClientHello as a client library sends it (sni=None: no SNI)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = ctx.wrap_bio(incoming, outgoing, server_hostname=sni)
    try:
        tls.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def can_bind(address):
    try:
        with socket.socket() as s:
            s.bind((address, 0))
        return True
    except OSError:
        return False


class ParseTest(unittest.TestCase):
    def test_parse_sni_from_real_client_hello(self):
        self.assertEqual(gate.parse_sni(client_hello("ABC123.dns.example.com")), "abc123.dns.example.com")
        self.assertIsNone(gate.parse_sni(client_hello(None)))
        self.assertIsNone(gate.parse_sni(b"GET / HTTP/1.1\r\n\r\n"))
        self.assertIsNone(gate.parse_sni(b"\x16\x03\x01\x00"))


class GateTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.domain = d / "domain"
        self.cidrs = d / "cidrs"
        self.domain.write_text("current.dns.example.com\n")
        self.cidrs.write_text("127.0.0.0/8\n")
        self.received, self.sources = [], []

        async def backend(reader, writer):
            self.sources.append(writer.get_extra_info("peername")[0])
            data = await reader.read(65536)
            self.received.append(data)
            writer.write(b"BACKEND-OK")
            await writer.drain()
            await reader.read()          # hold open until the gate closes
            writer.close()

        self.backend = await asyncio.start_server(backend, "127.0.0.1", 0)
        linux_sources = can_bind("127.0.0.2") and can_bind("127.0.0.3")
        self.check_sources = linux_sources
        self.saved = {k: getattr(gate, k) for k in ("DOMAIN_FILE", "CIDR_FILE", "BACKEND_PORT",
                                                    "CLIENT_SRC", "OTHER_SRC", "HELLO_TIMEOUT")}
        gate.DOMAIN_FILE, gate.CIDR_FILE = str(self.domain), str(self.cidrs)
        gate.BACKEND_PORT = self.backend.sockets[0].getsockname()[1]
        gate.CLIENT_SRC = "127.0.0.2" if linux_sources else "127.0.0.1"
        gate.OTHER_SRC = "127.0.0.3" if linux_sources else "127.0.0.1"
        gate.HELLO_TIMEOUT = 2
        gate._CACHE.clear()
        gate.ACTIVE.clear()
        self.server = await asyncio.start_server(gate.handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        for k, v in self.saved.items():
            setattr(gate, k, v)
        # Do not await wait_closed(): since Python 3.12 it also waits for every
        # accepted connection, and relayed test connections may still be open.
        for srv in (self.server, self.backend):
            srv.close()
            if hasattr(srv, "close_clients"):
                srv.close_clients()
        for w in list(gate.ACTIVE):
            w.close()
        self.tmp.cleanup()

    async def connect(self, payload):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        writer.write(payload)
        await writer.drain()
        return reader, writer

    async def test_current_name_is_relayed_unchanged(self):
        hello = client_hello("current.dns.example.com")
        reader, writer = await self.connect(hello)
        self.assertEqual(await asyncio.wait_for(reader.read(100), 3), b"BACKEND-OK")
        self.assertEqual(self.received, [hello])
        writer.close()

    async def test_old_or_missing_name_is_closed_before_backend(self):
        for payload in (client_hello("old.dns.example.com"), client_hello(None), b"\x00" * 64):
            reader, writer = await self.connect(payload)
            self.assertEqual(await asyncio.wait_for(reader.read(100), 3), b"")
            writer.close()
        self.assertEqual(self.received, [])

    async def test_reset_cuts_connections_opened_with_the_previous_name(self):
        old_reader, old_writer = await self.connect(client_hello("current.dns.example.com"))
        self.assertEqual(await asyncio.wait_for(old_reader.read(100), 3), b"BACKEND-OK")
        # Reset: the domain file now names a new host (mtime must change).
        await asyncio.sleep(0.02)
        self.domain.write_text("fresh.dns.example.com\n")
        new_reader, new_writer = await self.connect(client_hello("fresh.dns.example.com"))
        self.assertEqual(await asyncio.wait_for(new_reader.read(100), 3), b"BACKEND-OK")
        self.assertEqual(gate.cut_stale(), 1)
        self.assertEqual(await asyncio.wait_for(old_reader.read(100), 3), b"")
        # Only the connection using the current name stays admitted.
        self.assertEqual(sorted(gate.ACTIVE.values()), ["fresh.dns.example.com"])
        reader, writer = await self.connect(client_hello("current.dns.example.com"))
        self.assertEqual(await asyncio.wait_for(reader.read(100), 3), b"", "old name must now be refused")
        for w in (old_writer, new_writer, writer):
            w.close()

    async def test_client_networks_use_the_client_source_address(self):
        if not self.check_sources:
            self.skipTest("127.0.0.2/127.0.0.3 not bindable here (non-Linux loopback)")
        reader, writer = await self.connect(client_hello("current.dns.example.com"))
        await asyncio.wait_for(reader.read(100), 3)
        writer.close()
        self.cidrs.write_text("203.0.113.0/24\n")
        await asyncio.sleep(0.02)
        self.cidrs.write_text("203.0.113.0/24 \n")
        reader, writer = await self.connect(client_hello("current.dns.example.com"))
        await asyncio.wait_for(reader.read(100), 3)
        writer.close()
        self.assertEqual(self.sources, ["127.0.0.2", "127.0.0.3"])

    def test_is_client_handles_ipv4_mapped_addresses(self):
        self.assertTrue(gate.is_client("::ffff:127.0.0.9"))
        self.assertFalse(gate.is_client("198.51.100.1"))


if __name__ == "__main__":
    unittest.main()
