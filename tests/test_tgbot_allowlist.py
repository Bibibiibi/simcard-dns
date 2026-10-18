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

    GEO_OFF = "state\toff\ncountries\tHK,MO,TW\nports\t-\nupdated\t-\nv4\t0\nv6\t0\nactive\tno\nblocked\t0\n"
    GEO_ON = ("state\ton\ncountries\tHK,MO,TW\nports\t22,853,8111\nupdated\t20261018\n"
              "v4\t4321\nv6\t987\nactive\tyes\nblocked\t42\n")

    def test_view_lists_asns_with_delete_buttons(self):
        self.fake({"--list-client-asns": (True,
            "AS136167\tCHINATELECOM-AS-AP (CTMO)\t6\nAS63527\tCTGL <Global>\t4\nOTHER\t1\t192.0.2.0/24\n"),
            "--geo-allow": (True, self.GEO_OFF)})
        text, kb = bot.allowlist_view()
        self.assertIn("<b>AS136167</b>  CHINATELECOM-AS-AP (CTMO)（6 段）", text)
        self.assertIn("CTGL &lt;Global&gt;", text)
        self.assertIn("手动网段 1 段", text)
        self.assertIn("地区限制：<b>未开启</b>", text)
        self.assertIn("香港、澳门、台湾", text)
        data = [b["callback_data"] for row in kb for b in row]
        self.assertEqual(data, ["asndel:AS136167", "asndel:AS63527", "asn:add", "menu:geo", "menu:main"])

    def test_geo_card_when_on(self):
        self.fake({"--geo-allow": (True, self.GEO_ON)})
        text, kb = bot.geo_view()
        self.assertIn("<b>🌏 港澳台连接</b>", text)
        self.assertIn("地区限制：<b>已开启</b>（生效中）", text)
        self.assertIn("端口 22/853/8111", text)
        self.assertIn("名单日期 2026-10-18：IPv4 4321 段、IPv6 987 段；已拦截 42 个连接包", text)
        data = [b["callback_data"] for row in kb for b in row]
        self.assertEqual(data, ["geo:off", "geo:update", "menu:main"])
        self.assertEqual(self.calls, [["--geo-allow", "status"]])

    def test_geo_card_when_off_inactive_or_unreadable(self):
        self.fake({"--geo-allow": (True, self.GEO_OFF)})
        text, kb = bot.geo_view()
        self.assertIn("SSH、DoT 853 和 iOS 描述文件 8111", text)
        self.assertEqual([b["callback_data"] for row in kb for b in row], ["geo:on", "menu:main"])
        self.fake({"--geo-allow": (True, self.GEO_ON.replace("active\tyes", "active\tno"))})
        self.assertIn("防火墙里没有生效", bot.geo_view()[0])
        self.fake({"--geo-allow": (False, "boom")})
        text, kb = bot.geo_view()
        self.assertIn("地区限制：读取状态失败", text)
        self.assertEqual([b["callback_data"] for row in kb for b in row], ["menu:main"])

    def test_main_menu_geo_button_shows_state(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            conf = os.path.join(d, "geo-allow.conf")
            self.addCleanup(setattr, bot, "GEO_CONF_PATH", bot.GEO_CONF_PATH)
            bot.GEO_CONF_PATH = conf
            label = lambda: [b for row in bot.main_menu() for b in row if b["callback_data"] == "menu:geo"][0]["text"]
            self.assertEqual(label(), "🌏 港澳台连接 · 已关闭")
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write("# x\nGEO_ALLOW=on\nGEO_PORTS=22,853,8111\n")
            self.assertEqual(label(), "🌏 港澳台连接 · 已开启")
            with open(conf, "a", encoding="utf-8") as fh:
                fh.write("GEO_ALLOW=off\n")
            self.assertEqual(label(), "🌏 港澳台连接 · 已关闭")

    def test_geo_confirm_and_actions_call_the_cli(self):
        text, kb = bot.geo_confirm_on()
        self.assertIn("无法 SSH 登录", text)
        self.assertEqual(kb[0][0]["callback_data"], "geook:on")
        self.fake({"--geo-allow": (True, "")})
        self.assertIn("已开启地区限制", bot.op_geo("on"))
        self.assertIn("已更新地区名单", bot.op_geo("update"))
        self.fake({"--geo-allow": (False, "Refusing: admin session(s) from 8.8.8.8 are outside HK,MO,TW")})
        out = bot.op_geo("off")
        self.assertIn("关闭地区限制失败", out)
        self.assertIn("8.8.8.8", out)
        self.assertEqual(self.calls, [["--geo-allow", "on"], ["--geo-allow", "update"], ["--geo-allow", "off"]])

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
        self.assertIn("menu:geo", data)


class GeoFlowTest(unittest.TestCase):
    """Drives the real handle_callback paths for the regional allowlist buttons."""

    def setUp(self):
        self.sent, self.calls = [], []
        for name in ("authorized", "answer_callback_async", "background", "tg", "run2"):
            self.addCleanup(setattr, bot, name, getattr(bot, name))
        bot.PENDING.clear()
        bot.BUSY.clear()
        bot.authorized = lambda uid: True
        bot.answer_callback_async = lambda cb_id: None
        bot.background = lambda fn, *args: fn(*args)

        def tg(method, **params):
            if method in ("editMessageText", "sendMessage"):
                self.sent.append(params)
            return {"ok": True, "result": {"message_id": 500}}

        def run2(argv, timeout=120, inp=None):
            self.calls.append(argv[2:])
            if argv[2] == "--geo-allow" and argv[3] == "status":
                return True, AllowlistTest.GEO_ON
            return True, ""

        bot.tg, bot.run2 = tg, run2

    def cb(self, data):
        bot.handle_callback({"id": "cb", "from": {"id": 1}, "data": data,
                             "message": {"chat": {"id": 9}, "message_id": 300}})
        return self.sent[-1]

    def test_main_menu_button_opens_geo_card(self):
        card = self.cb("menu:geo")
        self.assertIn("港澳台连接", card["text"])
        self.assertIn("端口 22/853/8111", card["text"])
        self.assertEqual(self.calls, [["--geo-allow", "status"]])

    def test_on_needs_confirmation_then_runs(self):
        shown = self.cb("geo:on")
        self.assertIn("确认开启地区限制", shown["text"])
        self.assertEqual(self.calls, [])
        done = self.cb("geook:on")
        self.assertIn(["--geo-allow", "on"], self.calls)
        self.assertIn("已开启地区限制", done["text"])
        self.assertIn("<b>🌏 港澳台连接</b>", done["text"])
        self.assertIn(["--geo-allow", "status"], self.calls)

    def test_off_and_update_run_directly(self):
        self.cb("geo:off")
        self.cb("geo:update")
        self.assertIn(["--geo-allow", "off"], self.calls)
        self.assertIn(["--geo-allow", "update"], self.calls)


if __name__ == "__main__":
    unittest.main()
