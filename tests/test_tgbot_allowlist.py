import importlib.util
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_allowlist", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


class AllowlistTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.real_run2 = bot.run2
        self.addCleanup(setattr, bot, "run2", self.real_run2)

    def fake(self, outputs):
        def run2(argv, timeout=120, inp=None):
            self.calls.append(argv[2:])
            return outputs[argv[2]]
        bot.run2 = run2

    def test_parse_asn(self):
        self.assertEqual(bot.parse_asn("AS63527"), "AS63527")
        self.assertEqual(bot.parse_asn(" as063527 "), "AS63527")
        self.assertEqual(bot.parse_asn("63527"), "AS63527")
        for bad in ("", "AS0", "AS-1", "63527;rm", "AS 1 2", "x63527"):
            self.assertIsNone(bot.parse_asn(bad), bad)

    def test_view_lists_asns_with_delete_buttons(self):
        self.fake({"--list-client-asns": (True,
            "AS136167\tCHINATELECOM-AS-AP (CTMO)\t6\nAS63527\tCTGL <Global>\t4\nOTHER\t1\t192.0.2.0/24\n")})
        text, kb = bot.allowlist_view()
        self.assertIn("<b>AS136167</b>  CHINATELECOM-AS-AP (CTMO)（6 段）", text)
        self.assertIn("CTGL &lt;Global&gt;", text)
        self.assertIn("手动网段 1 段", text)
        data = [b["callback_data"] for row in kb for b in row]
        self.assertEqual(data, ["asndel:AS136167", "asndel:AS63527", "asn:add", "menu:main"])

    def test_lookup_confirmation_and_big_network_warning(self):
        self.fake({"--lookup-client-asn": (True, "AS63527\tCTGL\t4\t1280\n")})
        text, kb = bot.op_lookup_asn("AS63527")
        self.assertIn("4 段，共 1,280 个地址", text)
        self.assertNotIn("很大的网络", text)
        self.assertEqual(kb[0][0]["callback_data"], "asnok:AS63527")
        self.fake({"--lookup-client-asn": (True, "AS4134\tCHINANET\t900\t120000000\n")})
        text, _ = bot.op_lookup_asn("AS4134")
        self.assertIn("很大的网络", text)
        self.fake({"--lookup-client-asn": (False, "ASN lookup failed for AS1: timeout\n[exit code 1]")})
        text, kb = bot.op_lookup_asn("AS1")
        self.assertIn("查询 <b>AS1</b> 失败", text)
        self.assertEqual(kb[0][0]["callback_data"], "asn:add")

    def test_add_and_delete_call_the_cli(self):
        self.fake({"--add-client-asn": (True, ""), "--del-client-asn": (False, "Refusing to remove AS136167: empty")})
        self.assertIn("已添加 <b>AS63527</b>", bot.op_add_asn("AS63527"))
        self.assertIn("删除 AS136167 失败", bot.op_del_asn("AS136167"))
        self.assertEqual(self.calls, [["--add-client-asn", "AS63527"], ["--del-client-asn", "AS136167"]])

    def test_main_menu_has_allowlist(self):
        data = [b["callback_data"] for row in bot.main_menu() for b in row]
        self.assertIn("menu:allow", data)
        self.assertIn("act:clients", data)


if __name__ == "__main__":
    unittest.main()
