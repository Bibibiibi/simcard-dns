"""Hermetic endpoint classification and responsive UI regressions."""
import importlib.util
import subprocess
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class ProbeTest(unittest.TestCase):
    def probe(self, kind, rc, host="example.test", port="443"):
        script = '''source lib/exits.sh
exit_type() { echo "$TYPE"; }
exit_reachable() { return "$RC"; }
exit_probe_state test "$HOST" "$PORT"
'''
        import os
        env = dict(os.environ, TYPE=kind, RC=str(rc), HOST=host, PORT=port)
        return subprocess.check_output(["bash", "-c", script], cwd=ROOT,
                                       env=env, text=True).strip()

    def test_tcp_states(self):
        for rc, state in [(0, "UP"), (1, "DOWN"), (2, "DNS_ERROR"),
                          (124, "TIMEOUT"), (3, "UNKNOWN")]:
            with self.subTest(rc=rc):
                self.assertEqual(self.probe("shadowsocks", rc), state)

    def test_udp_not_reported_down(self):
        for kind in ("hysteria", "hysteria2", "tuic", "wireguard"):
            self.assertEqual(self.probe(kind, 1), "UDP_UNTESTED")

    def test_missing_endpoint(self):
        self.assertEqual(self.probe("shadowsocks", 0, "", ""), "UNKNOWN")


class ResponsiveUiTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("probe_bot", ROOT / "lib/tgbot.py")
        self.bot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bot)

    def test_stalled_edit_does_not_lock_generation(self):
        started, release, advanced = threading.Event(), threading.Event(), threading.Event()
        bot = self.bot
        bot.CONSOLE[1] = 2

        def slow_edit(*args):
            started.set()
            release.wait(3)
            return True

        with patch.object(bot, "edit_message", side_effect=slow_edit):
            worker = threading.Thread(target=lambda: bot.upsert_console(1, "slow", generation=0))
            worker.start()
            self.assertTrue(started.wait(1))
            nav = threading.Thread(target=lambda: (bot._bump_chat_generation(1), advanced.set()))
            nav.start()
            try:
                self.assertTrue(advanced.wait(1), "network request held generation lock")
            finally:
                release.set()
                worker.join(3)
                nav.join(3)

    def test_busy_navigation_but_not_mutation(self):
        bot = self.bot
        bot.BUSY.add((1, 2))
        cb = {"id": "x", "from": {"id": 1}, "message": {
            "chat": {"id": 1}, "message_id": 2}, "data": "menu:main"}
        with patch.object(bot, "authorized", return_value=True), \
             patch.object(bot, "answer_callback_async"), patch.object(bot, "edit") as edit, \
             patch.object(bot, "tg", return_value={}) as tg:
            bot.handle_callback(cb)
            edit.assert_called_once()
            cb["data"] = "exit:local"
            bot.handle_callback(cb)
            tg.assert_called_once()

    def test_overlapping_views_keep_busy_until_last_finishes(self):
        bot = self.bot
        bot._acquire_busy((1, 2))
        bot._acquire_busy((1, 2))
        bot._release_busy((1, 2))
        self.assertIn((1, 2), bot.BUSY)
        bot._release_busy((1, 2))
        self.assertNotIn((1, 2), bot.BUSY)

    def test_ip_probe_has_shared_deadline(self):
        bot = self.bot
        with patch.object(bot.time, "monotonic", side_effect=[0, 0, 7]), \
             patch.object(bot, "run2", return_value=(False, "")) as run:
            self.assertEqual(bot._exit_ip(), "")
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.kwargs["timeout"], 6)

    def test_ip_probe_rejects_invalid_address(self):
        with patch.object(self.bot, "run2", return_value=(True, "999.1.1.1")):
            self.assertEqual(self.bot._exit_ip(), "")

    def test_diagnostics_explain_unknown_states(self):
        for state, label in [("DNS_ERROR", "DNS"), ("UDP_UNTESTED", "UDP"),
                             ("UP", "未验证代理")]:
            self.assertIn(label, self.bot._format_check_exit_row("node", "host:1", state))


if __name__ == "__main__":
    unittest.main()
