"""Long bot messages must stay within Telegram limits with balanced HTML.

Regression for: a rule list / allowlist longer than 4096 characters used to be
sliced mid-tag, Telegram rejected it ("can't parse entities"), the fallback
deleted the console message first and the replacement failed the same way,
leaving the chat with no menu at all.
"""
import importlib.util
from pathlib import Path
import re
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_html_limits", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

TAG_RE = re.compile(r"<(/?)([a-z]+)[^<>]*>")


def balanced(fragment):
    stack = []
    for m in TAG_RE.finditer(fragment):
        if m.group(1):
            if not stack or stack.pop() != m.group(2):
                return False
        else:
            stack.append(m.group(2))
    return not stack


def long_rules_message(n=400):
    body = "\n".join("%d. DOMAIN-SUFFIX,site-%03d.example.com,台湾 &amp; <b>x</b>" % (i, i) for i in range(n))
    return "📋 <b>当前分流规则</b>（%d 条）：\n<pre>%s</pre>" % (n, body)


class FitHtmlTest(unittest.TestCase):
    def test_short_text_is_untouched(self):
        self.assertEqual(bot.fit_html("<b>hi</b>"), "<b>hi</b>")
        self.assertEqual(bot.fit_html(None), "")

    def test_long_text_is_cut_with_balanced_tags(self):
        out = bot.fit_html(long_rules_message())
        self.assertLessEqual(len(out), bot.TG_TEXT_LIMIT)
        self.assertTrue(balanced(out), out[-200:])
        self.assertTrue(out.endswith(bot._TRUNCATED_MARK))
        self.assertIn("</pre>", out)

    def test_cut_never_leaves_partial_tag_or_entity(self):
        for limit in range(60, 140):
            text = "<a href=\"https://example.com/x\">link &amp; more</a> " * 20
            out = bot.fit_html(text, limit=limit)
            self.assertLessEqual(len(out), limit)
            self.assertTrue(balanced(out), (limit, out))
            self.assertNotRegex(out, r"<[^>]*$")
            self.assertNotRegex(out, r"&[a-z#0-9]*$")


class SplitHtmlTest(unittest.TestCase):
    def test_pieces_are_balanced_and_sized(self):
        text = long_rules_message()
        pieces = bot.split_html(text)
        self.assertGreater(len(pieces), 1)
        for piece in pieces:
            self.assertLessEqual(len(piece), bot.TG_CHUNK_SIZE)
            self.assertTrue(balanced(piece), piece[-200:])
        # Every original line survives in exactly one piece, and the <pre>
        # block is reopened at the start of every continuation piece.
        joined = "".join(re.sub(r"</?pre>", "", p) for p in pieces)
        self.assertEqual(joined, re.sub(r"</?pre>", "", text))
        for piece in pieces[1:]:
            self.assertTrue(piece.startswith("<pre>"), piece[:40])

    def test_short_text_is_single_piece(self):
        self.assertEqual(bot.split_html("<b>ok</b>"), ["<b>ok</b>"])
        self.assertEqual(bot.split_html(""), [""])


class FakeApi:
    def __init__(self, edit_ok=False, send_ok=True):
        self.calls = []
        self.edit_ok = edit_ok
        self.send_ok = send_ok

    def __call__(self, method, **params):
        self.calls.append((method, params))
        if method == "editMessageText":
            return {"ok": True} if self.edit_ok else {"ok": False, "description": "message to edit not found"}
        if method == "sendMessage":
            if self.send_ok:
                return {"ok": True, "result": {"message_id": 501}}
            return {"ok": False, "description": "Bad Request: can't parse entities"}
        return {"ok": True, "result": {}}


class EditFallbackTest(unittest.TestCase):
    def setUp(self):
        bot.CONSOLE.clear()
        self.deleted = []
        bot.delete_message = lambda chat_id, mid: self.deleted.append(mid)
        self.cb = {"message": {"chat": {"id": 7}, "message_id": 300}}

    def test_edit_sends_fitted_text(self):
        api = FakeApi(edit_ok=True)
        bot.tg = api
        bot.edit(self.cb, long_rules_message())
        sent = api.calls[-1][1]["text"]
        self.assertLessEqual(len(sent), bot.TG_TEXT_LIMIT)
        self.assertTrue(balanced(sent))
        self.assertEqual(bot.CONSOLE[7], 300)

    def test_fallback_deletes_old_console_only_after_replacement_exists(self):
        api = FakeApi(edit_ok=False, send_ok=True)
        bot.tg = api
        bot.edit(self.cb, "<b>menu</b>")
        methods = [m for m, _ in api.calls]
        self.assertEqual(methods, ["editMessageText", "sendMessage"])
        self.assertEqual(self.deleted, [300])
        self.assertEqual(bot.CONSOLE[7], 501)

    def test_fallback_keeps_old_console_when_send_fails(self):
        api = FakeApi(edit_ok=False, send_ok=False)
        bot.tg = api
        bot.CONSOLE[7] = 300
        bot.edit(self.cb, "<b>menu</b>")
        self.assertEqual(self.deleted, [])
        self.assertEqual(bot.CONSOLE[7], 300)

    def test_send_splits_long_html_into_valid_messages(self):
        api = FakeApi(edit_ok=True)
        bot.tg = api
        bot.send(7, long_rules_message(), keyboard=[[{"text": "x", "callback_data": "y"}]])
        texts = [p["text"] for m, p in api.calls if m == "sendMessage"]
        self.assertGreater(len(texts), 1)
        for t in texts:
            self.assertLessEqual(len(t), bot.TG_CHUNK_SIZE)
            self.assertTrue(balanced(t))
        self.assertIn("reply_markup", api.calls[-1][1])
        self.assertNotIn("reply_markup", api.calls[0][1])


if __name__ == "__main__":
    unittest.main()
