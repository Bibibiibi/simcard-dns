import importlib.util
import ipaddress
import tempfile
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_clients", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"


def proc_addr(ip, port):
    """Encode like the kernel: each 32-bit word of the address in little-endian."""
    raw = ipaddress.ip_address(ip).packed
    raw = b"".join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
    return "%s:%04X" % (raw.hex().upper(), port)


def row(local, remote, state):
    return "   0: %s %s %s 00000000:00000000 00:00000000 00000000     0        0 1\n" % (
        proc_addr(*local), proc_addr(*remote), state)


class ClientsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)
        self.tcp, self.tcp6, self.cidrs = d / "tcp", d / "tcp6", d / "cidrs"
        server = "10.18.10.30"
        self.tcp.write_text(HEADER + "".join([
            row(("0.0.0.0", 443), ("0.0.0.0", 0), "0A"),
            row(("0.0.0.0", 22), ("0.0.0.0", 0), "0A"),
            row(("127.0.0.1", 8443), ("0.0.0.0", 0), "0A"),
            row((server, 443), ("103.143.92.184", 6836), "01"),
            row((server, 443), ("103.143.92.184", 6837), "01"),
            row((server, 22), ("192.0.2.73", 50000), "01"),
            # wa-shim -> sniproxy backend on loopback: internal, not a client.
            row(("127.0.0.1", 8443), ("127.0.0.1", 40000), "01"),
            # Outbound proxy connection: local port is not a listening port.
            row((server, 41000), ("142.250.0.1", 443), "01"),
            # Closed/other states are ignored.
            row((server, 443), ("198.51.100.9", 1234), "06"),
        ]))
        self.tcp6.write_text(HEADER + "".join([
            row(("::", 853), ("::", 0), "0A"),
            row(("::ffff:10.18.10.30", 853), ("::ffff:103.143.92.184", 46096), "01"),
        ]))
        self.cidrs.write_text("74.119.64.0/21 103.143.92.0/23\n")

    def test_inbound_clients_by_ip_and_port(self):
        clients = bot.inbound_clients((str(self.tcp), str(self.tcp6)))
        self.assertEqual(clients, {
            ipaddress.ip_address("103.143.92.184"): {443: 2, 853: 1},
            ipaddress.ip_address("192.0.2.73"): {22: 1},
        })

    def test_card_marks_client_networks(self):
        text = bot.op_clients((str(self.tcp), str(self.tcp6)), str(self.cidrs))
        self.assertIn("<code>103.143.92.184</code>  ✅ 客户端网段", text)
        self.assertIn("DNS:853×1", text)
        self.assertIn("代理:443×2", text)
        self.assertIn("<code>192.0.2.73</code>  ⚪ 网段外", text)
        self.assertNotIn("127.0.0.1", text)
        self.assertNotIn("142.250.0.1", text)
        self.assertNotIn("198.51.100.9", text)

    def test_empty_and_missing_tables(self):
        text = bot.op_clients((str(self.tcp) + ".missing",), str(self.cidrs))
        self.assertIn("当前没有外部连接", text)

    def test_wired_into_menu_and_commands(self):
        buttons = [b["callback_data"] for r in bot.main_menu() for b in r]
        self.assertIn("act:clients", buttons)
        self.assertIn("clients", [c for c, _ in bot.BOT_COMMANDS])


if __name__ == "__main__":
    unittest.main()
