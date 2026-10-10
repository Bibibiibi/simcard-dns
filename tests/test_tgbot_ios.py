import importlib.util
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_ios", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

CHAT_ID = 91


class FakeApi:
    def __init__(self):
        self.calls = []

    def __call__(self, method, **params):
        self.calls.append((method, params))
        if method == "sendPhoto":
            return {"ok": True, "result": {"message_id": 701}}
        return {"ok": True, "result": {}}

    def methods(self, name):
        return [params for method, params in self.calls if method == name]


class IosQrFlowTest(unittest.TestCase):
    def setUp(self):
        bot.PENDING.clear()
        bot.CONSOLE.clear()
        bot.BUSY.clear()
        bot.authorized = lambda uid: True
        bot.answer_callback_async = lambda cb_id: None
        bot.background = lambda fn, *args: fn(*args)
        self.api = FakeApi()
        bot.tg = self.api
        bot.delete_message = lambda chat_id, message_id: self.deleted.append((chat_id, message_id)) or True
        self.deleted = []

    def callback(self, data, message_id=300):
        bot.handle_callback({
            "id": "cb", "from": {"id": 1}, "data": data,
            "message": {"chat": {"id": CHAT_ID}, "message_id": message_id},
        })

    def test_back_deletes_fresh_qr_without_reposting_menu(self):
        bot.CONSOLE[CHAT_ID] = 300
        self.callback("ios_back:300", message_id=701)
        self.assertEqual(self.deleted, [(CHAT_ID, 701)])
        self.assertEqual(self.api.methods("sendMessage"), [])
        self.assertEqual(self.api.methods("editMessageText"), [])
        self.assertEqual(bot.CONSOLE[CHAT_ID], 300)

    def test_back_delete_failure_warns_without_reposting_menu(self):
        bot.CONSOLE[CHAT_ID] = 300
        bot.delete_message = lambda *args: False
        self.callback("ios_back:300", message_id=701)
        self.assertEqual(bot.CONSOLE[CHAT_ID], 300)
        self.assertEqual(self.api.methods("editMessageText"), [])
        self.assertEqual(self.api.methods("sendMessage"), [])
        self.assertTrue(self.api.methods("answerCallbackQuery"))

    def test_ios_action_does_not_edit_old_console_message(self):
        # The old console can be older than Telegram's 48-hour delete window.
        # QR delivery must not turn that old message into media or text.
        old = {"id": "cb", "from": {"id": 1}, "data": "act:ios",
               "message": {"chat": {"id": CHAT_ID}, "message_id": 300}}
        bot._read_file = lambda path: "example.com" if path.endswith(".domain") else ""
        bot.run2 = lambda argv, timeout=120, inp=None: (True, "")
        bot.send_photo = lambda chat_id, path, caption="", keyboard=None: 701
        bot.handle_callback(old)
        self.assertEqual(self.api.methods("editMessageText"), [])
        self.assertEqual(bot.CONSOLE.get(CHAT_ID), None)

    def test_expired_source_callback_still_deletes_qr(self):
        self.callback("ios_back:300", message_id=701)
        self.assertEqual(self.deleted, [(CHAT_ID, 701)])
        self.assertEqual(self.api.methods("sendMessage"), [])


if __name__ == "__main__":
    unittest.main()
