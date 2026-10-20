"""Status card line for the DoT DNS record self-check."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_dot_record", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


class DotRecordLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "dot-record.status")
        self.now = time.time()

    def write(self, **kv):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("".join("%s=%s\n" % item for item in kv.items()))

    def line(self):
        return bot.dot_record_line(now=self.now, path=self.path)

    def test_no_status_or_own_domain_shows_nothing(self):
        self.assertEqual(self.line(), "")
        self.write(state="not-cloudflare", checked=int(self.now))
        self.assertEqual(self.line(), "")

    def test_ok(self):
        self.write(state="ok", checked=int(self.now), recreated_at="")
        self.assertIn("解析：正常", self.line())
        self.assertNotIn("自动补建", self.line())

    def test_recently_recreated_is_shown_for_a_day(self):
        self.write(state="ok", checked=int(self.now), recreated_at=int(self.now - 600))
        self.assertIn("已自动补建", self.line())
        self.write(state="ok", checked=int(self.now), recreated_at=int(self.now - 2 * 86400))
        self.assertNotIn("已自动补建", self.line())

    def test_missing_error_and_stale(self):
        self.write(state="missing", checked=int(self.now))
        self.assertIn("自动补建失败", self.line())
        self.write(state="error", checked=int(self.now))
        self.assertIn("无法连上 Cloudflare", self.line())
        self.write(state="ok", checked=int(self.now - 7200))
        self.assertIn("超过 1 小时没有运行", self.line())

    def test_status_card_includes_the_line_under_the_domain(self):
        self.write(state="ok", checked=int(self.now))
        files = {"/etc/mosdns/.domain": "abc.dns.example.net", self.path: open(self.path).read()}
        real_read, real_active, real_metrics = bot._read_file, bot._is_active, bot.system_metrics
        self.addCleanup(setattr, bot, "_read_file", real_read)
        self.addCleanup(setattr, bot, "_is_active", real_active)
        self.addCleanup(setattr, bot, "system_metrics", real_metrics)
        self.addCleanup(setattr, bot, "DOT_CHECK_STATUS", bot.DOT_CHECK_STATUS)
        bot.DOT_CHECK_STATUS = self.path
        bot._read_file = lambda p: files.get(p, "")
        bot._is_active = lambda unit: "active"
        bot.system_metrics = lambda: "metrics"
        text = bot.op_status()
        domain_at = text.index("abc.dns.example.net")
        self.assertGreater(text.index("解析：正常"), domain_at)


if __name__ == "__main__":
    unittest.main()
