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


def row(local, remote, state, inode=1):
    return "   0: %s %s %s 00000000:00000000 00:00000000 00000000     0        0 %d\n" % (
        proc_addr(*local), proc_addr(*remote), state, inode)


def fake_proc(root, pid, comm, title, inodes):
    d = root / str(pid)
    (d / "fd").mkdir(parents=True)
    (d / "comm").write_text(comm + "\n")
    (d / "cmdline").write_bytes(title.encode() + b"\0")
    for n, inode in enumerate(inodes):
        (d / "fd" / str(n)).symlink_to("socket:[%d]" % inode)


SSH_LOG = """Invalid user ubuntu from 77.90.185.20 port 4000
Connection closed by invalid user ubuntu 77.90.185.20 port 4000 [preauth]
Connection closed by authenticating user root 77.90.185.20 port 4001 [preauth]
Disconnected from authenticating user root 45.140.193.140 port 9 [preauth]
Accepted publickey for root from 192.0.2.73 port 5000 ssh2: ED25519 SHA256:x
Connection closed by 1.2.3.4 port 7
"""


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
            row((server, 22), ("192.0.2.73", 50000), "01", inode=501),
            row((server, 22), ("77.90.185.20", 4002), "01", inode=502),
            # OpenSSH >= 9.8: per-connection processes are "sshd-session".
            row((server, 22), ("198.51.100.77", 4003), "01", inode=503),
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
        self.proc = d / "proc"
        # Logged-in session: monitor [priv] + user child root@notty share the socket.
        fake_proc(self.proc, 10, "sshd", "sshd: root [priv]", [501])
        fake_proc(self.proc, 11, "sshd", "sshd: root@notty", [501])
        # Brute-force attempt still authenticating.
        fake_proc(self.proc, 20, "sshd", "sshd: root [priv]", [502])
        fake_proc(self.proc, 21, "sshd", "sshd: root [net]", [502])
        # A non-sshd process holding the same socket must not count.
        fake_proc(self.proc, 30, "python3", "sshd: evil@notty", [502])
        fake_proc(self.proc, 40, "sshd-session", "sshd-session: alice [priv]", [503])
        fake_proc(self.proc, 41, "sshd-session", "sshd-session: alice@pts/0", [503])

    def card(self):
        return bot.op_clients((str(self.tcp), str(self.tcp6)), str(self.cidrs),
                              str(self.proc), SSH_LOG)

    def test_inbound_conns_by_ip_and_port(self):
        conns = bot._inbound_conns((str(self.tcp), str(self.tcp6)))
        seen = {}
        for ip, port, _ in conns:
            seen.setdefault(ip, {}).setdefault(port, 0)
            seen[ip][port] += 1
        self.assertEqual(seen, {
            ipaddress.ip_address("103.143.92.184"): {443: 2, 853: 1},
            ipaddress.ip_address("192.0.2.73"): {22: 1},
            ipaddress.ip_address("77.90.185.20"): {22: 1},
            ipaddress.ip_address("198.51.100.77"): {22: 1},
        })

    def test_card_marks_client_networks(self):
        text = self.card()
        self.assertIn("<code>103.143.92.184</code>  ✅ 客户端网段", text)
        self.assertIn("DNS:853×1", text)
        self.assertIn("代理:443×2", text)
        self.assertIn("<code>192.0.2.73</code>  ⚪ 网段外", text)
        self.assertNotIn("127.0.0.1", text)
        self.assertNotIn("142.250.0.1", text)
        self.assertNotIn("198.51.100.9", text)

    def test_ssh_login_state(self):
        text = self.card()
        logged, attacker = text.split("<code>192.0.2.73</code>")[1], text.split("<code>77.90.185.20</code>")[1]
        self.assertIn("🔓 SSH 已登录：root", logged.split("<code>")[0])
        self.assertIn("🔒 SSH 未登录（认证中），24h 内失败 2 次", attacker.split("<code>")[0])
        self.assertNotIn("evil", text)
        session = text.split("<code>198.51.100.77</code>")[1].split("<code>")[0]
        self.assertIn("🔓 SSH 已登录：alice", session)
        self.assertIn("失败尝试 3 次，来自 2 个 IP", text)
        self.assertIn("成功登录：<code>192.0.2.73</code>（root）", text)

    def test_ssh_log_summary(self):
        failed, accepted = bot.ssh_log_summary(SSH_LOG)
        self.assertEqual(failed, {"77.90.185.20": 2, "45.140.193.140": 1})
        self.assertEqual(accepted, {"192.0.2.73": {"root"}})

    def test_empty_and_missing_tables(self):
        text = bot.op_clients((str(self.tcp) + ".missing",), str(self.cidrs), str(self.proc), "")
        self.assertIn("当前没有外部连接", text)
        self.assertIn("无成功登录", text)

    def test_wired_into_menu_and_commands(self):
        buttons = [b["callback_data"] for r in bot.main_menu() for b in r]
        self.assertIn("act:clients", buttons)
        self.assertIn("clients", [c for c, _ in bot.BOT_COMMANDS])


if __name__ == "__main__":
    unittest.main()
