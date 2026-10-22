"""The smart router (exits/smart.type == router) is not an exit: the bot must
not offer it as a target and the router generator must refuse a policy that
maps a category to it instead of reading its own smart.yaml as a proxy."""
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_bot():
    spec = importlib.util.spec_from_file_location("tgbot_smart_exit", ROOT / "lib" / "tgbot.py")
    bot = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bot)
    return bot


class SmartNotAnExitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = pathlib.Path(self.tmp.name)
        self.exits = base / "exits"
        self.wg = base / "wg"
        self.rs = base / "rs"
        for d in (self.exits, self.wg, self.rs):
            d.mkdir()
        (self.exits / "smart.type").write_text("router\n")
        (self.exits / "smart.yaml").write_text('{"proxies": []}\n')
        (self.exits / "hk.type").write_text("shadowsocks\n")
        (self.exits / "hk.yaml").write_text(
            '{"proxies":[{"name":"x","type":"ss","server":"192.0.2.1","port":1,"cipher":"aes-128-gcm","password":"p"}]}\n')
        (self.wg / "pgw-tw.conf").write_text("[Interface]\nPrivateKey=x\n")
        self.rules = base / "rules.conf"
        self.rules.write_text("DOMAIN-SUFFIX,openai.com,AI\nFINAL,AI\n")
        self.policy = base / "policy-map.conf"

    def test_bot_hides_the_router_from_exit_names(self):
        bot = load_bot()
        bot.EXITS_DIR_PATH = str(self.exits)
        bot.WG_DIR_PATH = str(self.wg)
        self.assertEqual(bot.parse_exit_names(), ["local", "hk", "tw"])
        self.assertNotIn("smart", bot._targets())

    def run_gen(self):
        env = dict(os.environ, EXITS_DIR=str(self.exits), WG_DIR=str(self.wg),
                   PGW_RULESET_CACHE=str(self.rs), PGW_POLICY_MAP=str(self.policy))
        return subprocess.run(["python3", str(ROOT / "lib/mihomo-router-config.py"), str(self.rules)],
                              env=env, capture_output=True, text=True)

    def test_generator_refuses_a_policy_mapped_to_the_router(self):
        self.policy.write_text("AI=smart\n")
        result = self.run_gen()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("smart router itself", result.stderr)

    def test_generator_still_accepts_a_real_exit(self):
        self.policy.write_text("AI=hk\n")
        result = self.run_gen()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"hk"', result.stdout)


if __name__ == "__main__":
    unittest.main()
