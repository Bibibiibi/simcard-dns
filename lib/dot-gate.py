#!/usr/bin/env python3
"""DoT entry gate for simcard-dns.

Owns the public DoT port and lets a TLS connection through to mosdns only when
its ClientHello names the current DoT domain (SNI). Everything else -- a reset
(old) name, any other name, or no SNI at all, as sent by IP scanners -- is
closed before mosdns sees a byte. When the domain changes, connections opened
with the previous name are cut within a couple of seconds, so a reset takes
effect immediately even for clients that cached the server address.

TLS is not terminated here: the buffered ClientHello and the rest of the
stream are relayed unchanged. Because mosdns would then only see this process
as the peer, the client-network decision moves here: connections from the
client CIDRs come from CLIENT_SRC, all others from OTHER_SRC, and mosdns
matches those loopback sources instead of the real client address.
"""
import asyncio
import ipaddress
import logging
import os
import struct
import time

LISTEN_PORT = int(os.environ.get("DOT_GATE_PORT", "853"))
BACKEND_HOST = os.environ.get("DOT_GATE_BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("DOT_GATE_BACKEND_PORT", "8853"))
CLIENT_SRC = os.environ.get("DOT_GATE_CLIENT_SRC", "127.0.0.2")
OTHER_SRC = os.environ.get("DOT_GATE_OTHER_SRC", "127.0.0.3")
DOMAIN_FILE = os.environ.get("DOT_GATE_DOMAIN_FILE", "/opt/simcard-dns/etc/.domain")
CIDR_FILE = os.environ.get("DOT_GATE_CIDR_FILE", "/etc/mosdns/.client_cidrs")
HELLO_TIMEOUT = float(os.environ.get("DOT_GATE_HELLO_TIMEOUT", "5"))
CHECK_INTERVAL = float(os.environ.get("DOT_GATE_CHECK_INTERVAL", "2"))
MAX_CONN = int(os.environ.get("DOT_GATE_MAXCONN", "4096"))
MAX_RECORD = 16384 + 2048  # TLS plaintext record limit plus slack
REJECT_LOG_INTERVAL = float(os.environ.get("DOT_GATE_REJECT_LOG_INTERVAL", "60"))
REJECT_LOG_MAX = 4096
SNI_LOG_MAX = 253  # longest valid host name; anything longer is garbage

logging.basicConfig(level=logging.INFO, format="%(asctime)s dot-gate %(message)s")
LOG = logging.getLogger("dot-gate")
ACTIVE = {}  # writer -> SNI the connection was admitted with
HANDSHAKING = 0  # accepted connections still waiting for / checking the ClientHello
_CACHE = {}
_REJECTS = {}  # peer -> [last logged time, suppressed since, other names since, logged name]


def _cached(path, parse):
    """parse(text) of a small file, re-read only when its mtime changes."""
    try:
        mtime = os.stat(path).st_mtime_ns
    except OSError:
        return parse("")
    hit = _CACHE.get(path)
    if hit and hit[0] == mtime:
        return hit[1]
    try:
        with open(path, encoding="utf-8") as handle:
            value = parse(handle.read())
    except OSError:
        value = parse("")
    _CACHE[path] = (mtime, value)
    return value


def current_domain():
    return _cached(DOMAIN_FILE, lambda text: text.strip().lower().rstrip("."))


def client_networks():
    def parse(text):
        nets = []
        for item in text.replace(",", " ").split():
            try:
                nets.append(ipaddress.ip_network(item, strict=False))
            except ValueError:
                pass
        return nets
    return _cached(CIDR_FILE, parse)


def is_client(address):
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return any(ip.version == net.version and ip in net for net in client_networks())


def log_reject(peer, sni, now=None):
    """Log a rejected name at most once per interval per peer.

    A device still configured with a reset name retries several times a
    second, and a scanner can send a different name on every connection;
    keying on the peer alone keeps either from flooding the journal. The
    name is quoted and truncated so it cannot forge journal lines. Returns
    True when a line was written.
    """
    now = time.monotonic() if now is None else now
    shown = repr(sni[:SNI_LOG_MAX] + ("..." if len(sni) > SNI_LOG_MAX else ""))
    name = sni[:SNI_LOG_MAX]
    entry = _REJECTS.get(peer)
    if entry and now - entry[0] < REJECT_LOG_INTERVAL:
        entry[1] += 1
        if name != entry[3] and len(entry[2]) < 64:
            entry[2].add(name)
        return False
    suppressed = entry[1] if entry else 0
    names = len(entry[2]) if entry else 0
    if len(_REJECTS) >= REJECT_LOG_MAX:
        cutoff = now - REJECT_LOG_INTERVAL
        for stale in [k for k, v in _REJECTS.items() if v[0] < cutoff]:
            del _REJECTS[stale]
        if len(_REJECTS) >= REJECT_LOG_MAX:
            _REJECTS.clear()
    _REJECTS[peer] = [now, 0, set(), name]
    if suppressed:
        LOG.info("rejected sni=%s from %s (+%d more, %d other name(s) since last report)",
                 shown, peer, suppressed, names)
    else:
        LOG.info("rejected sni=%s from %s", shown, peer)
    return True


def parse_sni(record):
    """Server name from a TLS record holding a ClientHello, else None."""
    try:
        if len(record) < 9 or record[0] != 0x16 or record[5] != 0x01:
            return None
        body = record[9:9 + int.from_bytes(record[6:9], "big")]
        pos = 2 + 32                                  # legacy_version, random
        pos += 1 + body[pos]                          # session id
        pos += 2 + struct.unpack(">H", body[pos:pos + 2])[0]  # cipher suites
        pos += 1 + body[pos]                          # compression methods
        end = pos + 2 + struct.unpack(">H", body[pos:pos + 2])[0]
        pos += 2
        while pos + 4 <= end:
            ext_type, ext_len = struct.unpack(">HH", body[pos:pos + 4])
            pos += 4
            if ext_type == 0:                         # server_name
                names = body[pos + 2:pos + ext_len]
                i = 0
                while i + 3 <= len(names):
                    name_type, name_len = names[i], struct.unpack(">H", names[i + 1:i + 3])[0]
                    if name_type == 0:
                        return names[i + 3:i + 3 + name_len].decode("ascii").lower().rstrip(".")
                    i += 3 + name_len
                return None
            pos += ext_len
    except (IndexError, struct.error, UnicodeDecodeError):
        return None
    return None


async def read_client_hello(reader):
    header = await reader.readexactly(5)
    if header[0] != 0x16:
        raise ValueError("not a TLS handshake")
    length = struct.unpack(">H", header[3:5])[0]
    if length > MAX_RECORD:
        raise ValueError("oversized record")
    return header + await reader.readexactly(length)


async def pipe(reader, writer):
    """Copy one direction; on EOF half-close the other side (write_eof) so a
    client that shuts down its write side after the query still gets the
    answer. handle() closes both sockets once both directions are done."""
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, AttributeError, RuntimeError):
            pass


async def handle(reader, writer):
    global HANDSHAKING
    peer = writer.get_extra_info("peername") or ("?", 0)
    # Connections still reading their ClientHello hold a descriptor too, so
    # they count against the limit (a scanner sending 5 bytes and nothing
    # more would otherwise bypass it for HELLO_TIMEOUT seconds each).
    if len(ACTIVE) + HANDSHAKING >= MAX_CONN:
        writer.close()
        return
    HANDSHAKING += 1
    admitted = False
    backend_writer = None
    try:
        try:
            hello = await asyncio.wait_for(read_client_hello(reader), HELLO_TIMEOUT)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ValueError, ConnectionError, OSError):
            return
        sni = parse_sni(hello)
        domain = current_domain()
        if not sni or not domain or sni != domain:
            if sni:
                log_reject(peer[0], sni)
            return
        source = CLIENT_SRC if is_client(peer[0]) else OTHER_SRC
        try:
            backend_reader, backend_writer = await asyncio.open_connection(
                BACKEND_HOST, BACKEND_PORT, local_addr=(source, 0))
        except OSError as exc:
            LOG.warning("backend unavailable for %s: %s", peer[0], exc)
            return
        ACTIVE[writer] = sni
        admitted = True
        HANDSHAKING -= 1
        try:
            backend_writer.write(hello)
            await backend_writer.drain()
        except (ConnectionError, OSError):
            return
        await asyncio.gather(pipe(reader, backend_writer), pipe(backend_reader, writer))
    finally:
        ACTIVE.pop(writer, None)  # cut_stale() may already have removed it
        if not admitted:
            HANDSHAKING -= 1
        for w in (writer, backend_writer):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


def cut_stale():
    """Close admitted connections whose name is no longer the current one."""
    domain = current_domain()
    stale = [w for w, sni in ACTIVE.items() if sni != domain]
    for w in stale:
        ACTIVE.pop(w, None)
        try:
            w.close()
        except Exception:
            pass
    if stale:
        LOG.info("domain is now %s; closed %d connection(s) using a previous name", domain, len(stale))
    return len(stale)


async def watch_domain():
    while True:
        await asyncio.sleep(CHECK_INTERVAL)
        cut_stale()


async def main():
    server = await asyncio.start_server(handle, host=None, port=LISTEN_PORT, backlog=1024)
    LOG.info("listening :%d -> %s:%d (domain %s)", LISTEN_PORT, BACKEND_HOST, BACKEND_PORT, current_domain() or "unset")
    async with server:
        await asyncio.gather(server.serve_forever(), watch_domain())


if __name__ == "__main__":
    asyncio.run(main())
