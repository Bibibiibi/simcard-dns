import importlib.util
import tempfile
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_dot_reset", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


class DotResetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conf = Path(self.tmp.name) / "cloudflare.conf"
        self.real = (bot.CF_CONF_FILE, bot.run2)
        self.addCleanup(self.restore)
        bot.CF_CONF_FILE = str(self.conf)
        # Default argument binds at definition time; route through the module global.
        self.real_zone = bot.cloudflare_zone
        bot.cloudflare_zone = lambda path=None: self.real_zone(path or bot.CF_CONF_FILE)

    def restore(self):
        bot.CF_CONF_FILE, bot.run2 = self.real
        bot.cloudflare_zone = self.real_zone

    def first_button(self):
        return bot.dot_menu()[0][0]["callback_data"]

    def test_menu_switches_to_reset_when_cloudflare_connected(self):
        self.assertEqual(self.first_button(), "dot:domain")
        self.assertIn("未接入", bot.op_dot_status())
        self.conf.write_text("zone=example.net\nzone_id=z1\n")
        self.assertEqual(self.first_button(), "dot:reset")
        self.assertIn("已接入（<code>example.net</code>）", bot.op_dot_status())

    def test_reset_result_shows_new_domain_and_ios_button(self):
        self.conf.write_text("zone=example.net\nzone_id=z1\n")
        bot.run2 = lambda argv, timeout=120, inp=None: (True, "[OK] reset\nNEW_DOMAIN=abc123.dns.example.net\n")
        text, kb = bot.op_reset_domain()
        self.assertIn("<code>abc123.dns.example.net</code>", text)
        self.assertEqual(kb[0][0]["callback_data"], "act:ios")

    def test_reset_failure_keeps_old_domain_message(self):
        bot.run2 = lambda argv, timeout=120, inp=None: (False, "did not resolve within 90s\n[exit code 1]")
        text, kb = bot.op_reset_domain()
        self.assertIn("重置域名失败", text)
        self.assertIn("原域名保持不变", text)


if __name__ == "__main__":
    unittest.main()
