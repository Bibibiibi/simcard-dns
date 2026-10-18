import importlib.util
import os
import tempfile
import time
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tgbot_run_timeout", root / "lib" / "tgbot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class RunTimeoutTest(unittest.TestCase):
    def test_timeout_kills_grandchildren(self):
        # simcard-dns --add-exit spawns curl; a Bot timeout used to kill only the
        # outer bash and leave the download running as an orphan.
        with tempfile.TemporaryDirectory() as d:
            pidfile = Path(d) / "child.pid"
            ok, out = bot.run2(["bash", "-c", "sleep 300 & echo $! > %s; wait" % pidfile], timeout=1)
            self.assertFalse(ok)
            self.assertIn("执行超时", out)
            pid = int(pidfile.read_text())
            for _ in range(50):
                if not alive(pid):
                    break
                time.sleep(0.05)
            self.assertFalse(alive(pid), "grandchild must be killed with the group")

    def test_normal_output_and_stdin(self):
        ok, out = bot.run2(["bash", "-c", "cat; exit 3"], inp="hello\n", timeout=5)
        self.assertFalse(ok)
        self.assertEqual(out, "hello\n")
        self.assertIn("[exit code 3]", bot.run(["bash", "-c", "exit 3"], timeout=5))
        self.assertIn("command not found", bot.run(["/nonexistent-simcard-dns-cmd"], timeout=5))


if __name__ == "__main__":
    unittest.main()
