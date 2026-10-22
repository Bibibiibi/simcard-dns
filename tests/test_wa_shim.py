#!/usr/bin/env python3
import asyncio
import importlib.util
import ipaddress
import os
import struct
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.update(WA_SHIM_ALLOW_CIDR="103.143.92.0/23", WA_SHIM_SELF_IPS="127.0.0.1")
spec = importlib.util.spec_from_file_location("wa_shim", os.path.join(ROOT, "lib", "wa-shim.py"))
wa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wa)

assert wa.classify(b"ED\x00\x01x") == ("whatsapp", "known")
assert wa.classify(b"WA\x06\x03x") == ("whatsapp", "known")
assert wa.classify(b"ED\x00\x99x") == ("whatsapp", "new")
assert wa.classify(b"\x16\x03\x01") == ("backend", "")
assert wa.classify(b"E") == ("backend", "")
assert wa.source_allowed("103.143.92.184") and not wa.source_allowed("8.8.8.8")

question = wa.qname("g.whatsapp.net")
txid = 1234
packet = struct.pack(">HHHHHH", txid, 0x8180, 1, 1, 0, 0) + question + struct.pack(">HH", 1, 1)
packet += b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + ipaddress.ip_address("1.2.3.4").packed
assert wa.parse_answers(packet, txid, question) == ["1.2.3.4"]
assert wa.parse_answers(packet, 9999, question) == []
assert wa.hostport("1.1.1.1:5353", 53) == ("1.1.1.1", 5353)
assert wa.hostport("[2606:4700:4700::1111]:5353", 53) == ("2606:4700:4700::1111", 5353)
assert wa.hostport("2606:4700:4700::1111", 53) == ("2606:4700:4700::1111", 53)
assert wa.hostport("1.1.1.1", 53) == ("1.1.1.1", 53)
assert "127.0.0.1" in wa.SELF_IPS and "::1" in wa.SELF_IPS


async def fail_open_on_edge_error():
    calls = []
    original_relay, original_resolve, original_allowed = wa.relay, wa.resolve_edge, wa.source_allowed
    async def fake_relay(_reader, _writer, host, _port, _first):
        calls.append(host)
        return host == wa.BACKEND_HOST
    async def fake_resolve():
        return ["1.1.1.1"]
    wa.relay, wa.resolve_edge, wa.source_allowed = fake_relay, fake_resolve, lambda _src: True
    class Writer:
        def get_extra_info(self, _name): return ("103.143.92.184", 1234)
        def close(self): pass
    reader = asyncio.StreamReader()
    reader.feed_data(b"ED\0\1")
    reader.feed_eof()
    await wa.handle(reader, Writer())
    wa.relay, wa.resolve_edge, wa.source_allowed = original_relay, original_resolve, original_allowed
    return calls


assert asyncio.run(fail_open_on_edge_error()) == ["1.1.1.1", wa.BACKEND_HOST]


async def fragmented_peek():
    reader = asyncio.StreamReader()
    reader.feed_data(b"E")
    await asyncio.sleep(0)
    reader.feed_data(b"D\x00\x01rest")
    reader.feed_eof()
    return await wa.peek(reader)


assert asyncio.run(fragmented_peek()).startswith(b"ED\x00\x01")


async def negative_cache_and_single_flight():
    calls = []
    original_query = wa.query_a
    wa.query_a = lambda host, resolver: (calls.append(resolver), [])[1]
    wa._CACHE = ([], 0.0)
    try:
        assert await wa.resolve_edge() == []
        first = len(calls)
        assert first == len(wa.RESOLVERS), first
        assert await wa.resolve_edge() == []          # failure is cached ...
        assert len(calls) == first, calls             # ... so no new queries
        wa._CACHE = ([], 0.0)
        calls.clear()
        await asyncio.gather(*[wa.resolve_edge() for _ in range(6)])
        assert len(calls) == len(wa.RESOLVERS), calls  # single flight
        wa._CACHE = ([], time.time() - wa.DNS_NEGATIVE_TTL - 1)
        calls.clear()
        await wa.resolve_edge()
        assert len(calls) == len(wa.RESOLVERS), calls  # negative entry expired
    finally:
        wa.query_a = original_query
        wa._CACHE = ([], 0.0)


asyncio.run(negative_cache_and_single_flight())


async def idle_relay_times_out():
    class Writer:
        eof = False
        def write(self, _data): pass
        async def drain(self): pass
        def write_eof(self): self.eof = True
    saved = wa.IDLE_TIMEOUT
    wa.IDLE_TIMEOUT = 0.05
    try:
        reader = asyncio.StreamReader()  # peer never sends and never closes
        writer = Writer()
        await asyncio.wait_for(wa.pipe(reader, writer), 2)
        return writer.eof
    finally:
        wa.IDLE_TIMEOUT = saved


assert asyncio.run(idle_relay_times_out()) is True
print("wa shim policy OK")
