"""Hermetic Telegram UI tests: no network or real QR encoder."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IosQrFlowTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("ios_bot", ROOT / "lib/tgbot.py")
        self.bot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bot)
        b = self.bot
        b.authorized = lambda uid: True
        b.answer_callback_async = lambda cb: None
        b.background = lambda fn, *args: fn(*args)
        b._read_file = lambda path: "example.com"
        b.run2 = lambda *a, **kw: (True, "")
        self.calls = []
        self.existing = {300}
        self.undeletable = set()
        self.fail_send = False
        self.fail_edit = False
        self.fail_clear = False
        self.fail_photo = False
        b.tg = self.api
        b.send_photo = self.photo
        b.CONSOLE[91] = 300

    def api(self, method, **p):
        self.calls.append((method, p))
        mid = p.get("message_id")
        if method == "deleteMessage":
            if mid in self.undeletable or mid not in self.existing:
                return {"ok": False}
            self.existing.remove(mid)
        if method == "editMessageText" and (mid not in self.existing or self.fail_edit):
            return {"ok": False}
        if method == "editMessageReplyMarkup" and self.fail_clear:
            return {"ok": False}
        if method == "sendMessage":
            if self.fail_send:
                return {"ok": False}
            mid = 900 + len(self.methods("sendMessage"))
            self.existing.add(mid)
            return {"ok": True, "result": {"message_id": mid}}
        return {"ok": True}

    def photo(self, chat, path, caption, keyboard):
        self.calls.append(("photo", {"keyboard": keyboard, "path": path}))
        if self.fail_photo:
            return None
        self.existing.add(701)
        return 701

    def methods(self, name):
        return [p for m, p in self.calls if m == name]

    def cb(self, data, mid=300):
        return {"id": "cb", "from": {"id": 1}, "data": data,
                "message": {"chat": {"id": 91}, "message_id": mid}}

    def click(self, data, mid=300):
        self.bot.handle_callback(self.cb(data, mid))

    def test_delivery_before_menu_delete_and_back_recreates_menu(self):
        self.click("act:ios")
        self.assertNotIn(300, self.existing)
        self.assertEqual([m for m, p in self.calls], ["photo", "deleteMessage"])
        self.click("ios_back:300", 701)
        self.assertNotIn(701, self.existing)
        self.assertEqual(len(self.methods("sendMessage")), 1)
        self.assertEqual(self.methods("sendMessage")[0]["reply_markup"]["inline_keyboard"], self.bot.main_menu())
        self.assertFalse(Path(self.methods("photo")[0]["path"]).exists())

    def test_old_menu_falls_back_to_inactive_text_then_restores(self):
        self.undeletable.add(300)
        self.click("act:ios")
        self.assertEqual(self.methods("editMessageText")[0]["reply_markup"], {"inline_keyboard": []})
        self.click("ios_back:300", 701)
        self.assertEqual(self.bot.CONSOLE[91], 300)
        self.assertEqual(self.methods("sendMessage"), [])

    def test_restart_back_uses_callback_source(self):
        self.click("act:ios")
        self.bot.IOS_PAGES.clear()
        self.bot.CONSOLE.clear()
        self.click("ios_back:300", 701)
        self.assertEqual(len(self.methods("sendMessage")), 1)

    def test_qr_delete_failure_clears_buttons_and_warns(self):
        self.click("act:ios")
        self.undeletable.add(701)
        self.click("ios_back:300", 701)
        self.assertEqual(self.methods("editMessageReplyMarkup")[0]["reply_markup"], {"inline_keyboard": []})
        self.assertIn("手动删除", self.methods("answerCallbackQuery")[-1]["text"])
        self.assertIn(91, self.bot.CONSOLE)

    def test_clear_and_restore_failure_honest_alert(self):
        self.click("act:ios")
        self.undeletable.add(701)
        self.fail_clear = self.fail_send = True
        self.click("ios_back:300", 701)
        self.assertIn("按钮也未能清除", self.methods("answerCallbackQuery")[-1]["text"])
        self.assertIn("恢复失败", self.methods("answerCallbackQuery")[-1]["text"])

    def test_duplicate_click_and_back_do_not_duplicate_messages(self):
        self.click("act:ios")
        self.click("act:ios")
        self.assertEqual(len(self.methods("photo")), 1)
        self.click("ios_back:300", 701)
        self.click("ios_back:300", 701)
        self.assertEqual(len(self.methods("sendMessage")), 1)

    def test_busy_duplicate_does_not_invalidate_generation(self):
        queued = []
        self.bot.background = lambda fn, *a: queued.append(fn)
        self.click("act:ios")
        generation = self.bot._chat_generation(91)
        self.click("act:ios")
        self.assertEqual(generation, self.bot._chat_generation(91))
        queued[0]()
        self.assertEqual(len(self.methods("photo")), 1)

    def test_navigation_during_generation_suppresses_stale_delivery(self):
        self.bot.run2 = lambda *a, **kw: (self.bot._bump_chat_generation(91), "")
        self.click("act:ios")
        self.assertEqual(self.calls, [])
        self.assertIn(300, self.existing)

    def test_send_failure_keeps_menu_and_offers_retry(self):
        self.fail_photo = True
        self.click("act:ios")
        self.assertEqual(self.methods("deleteMessage"), [])
        self.assertEqual(self.methods("editMessageText")[-1]["reply_markup"]["inline_keyboard"], self.bot.main_menu())

    def test_missing_source_and_missing_url(self):
        self.assertIn("无法识别", self.bot.op_ios_send_inline({}))
        self.bot._read_file = lambda path: ""
        self.click("act:ios")
        self.assertEqual(self.methods("photo"), [])
        self.assertIn("未找到", self.methods("editMessageText")[-1]["text"])

    def test_encoder_failure_preserves_menu(self):
        self.bot.run2 = lambda *a, **kw: (False, "failed")
        self.click("act:ios")
        self.assertEqual(self.methods("photo"), [])
        self.assertIn(300, self.existing)

    def test_missing_source_on_back_still_sends_menu(self):
        self.existing.clear()
        self.existing.add(701)
        self.bot.CONSOLE.clear()
        self.click("ios_back:invalid", 701)
        self.assertEqual(len(self.methods("sendMessage")), 1)


if __name__ == "__main__":
    unittest.main()
