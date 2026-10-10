"""Bot setup and launcher tests with isolated files and mocked service calls."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BotSetupTests(unittest.TestCase):
    def run_setup(self, tmp, content, extra='', fail_restart=False):
        conf = Path(tmp) / 'etc'
        conf.mkdir()
        env_file = conf / 'tgbot.env'
        env_file.write_text(content)
        # Redirect only the unit destination; never write /etc/systemd or call systemctl.
        source = (ROOT / 'lib/services.sh').read_text().replace(
            '/etc/systemd/system/5gpn-tgbot.service', tmp + '/bot.service')
        script = source + f'''
BASE_DIR='{tmp}'; CONF_DIR='{conf}'; LIB_DIR='{ROOT}/lib'; SCRIPT_PATH='{ROOT}/install.sh'
info() {{ :; }}; ok() {{ echo SUCCESS; }}; warn() {{ :; }}; err() {{ echo "$*" >&2; }}
systemctl() {{ echo "$*" >> '{tmp}/calls'; {'[[ "$1" != restart ]]' if fail_restart else ':'}; }}
{extra}
setup_tgbot
'''
        env = dict(os.environ)
        for key in ('TG_BOT_TOKEN', 'TG_ADMIN_IDS', 'TG_BOT_SETTINGS_COLLECTED'):
            env.pop(key, None)
        result = subprocess.run(['bash', '-c', script], input='', text=True, capture_output=True, env=env)
        return result, env_file

    def test_existing_credentials_optional_settings_and_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, path = self.run_setup(tmp, 'TG_BOT_TOKEN="123:ABC_def"\nTG_ADMIN_IDS=12,34\nTG_STATE_FILE=/custom/state\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('TG_BOT_TOKEN=123:ABC_def', path.read_text())
            self.assertIn('TG_ADMIN_IDS=12,34', path.read_text())
            self.assertIn('TG_STATE_FILE=/custom/state', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            calls = (Path(tmp) / 'calls').read_text()
            self.assertIn('restart 5gpn-tgbot.service', calls)
            self.assertIn('is-active --quiet 5gpn-tgbot.service', calls)
            self.assertEqual((Path(tmp) / 'bin/tgbot.py').read_bytes(), (ROOT / 'lib/tgbot.py').read_bytes())

    def test_environment_is_not_executed(self):
        with tempfile.TemporaryDirectory() as tmp:
            content = f'TG_BOT_TOKEN=$(touch {tmp}/pwned)\nTG_ADMIN_IDS=12\n'
            result, path = self.run_setup(tmp, content)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(tmp) / 'pwned').exists())
            self.assertEqual(path.read_text(), content)

    def test_explicit_credentials_override_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, path = self.run_setup(tmp, 'TG_BOT_TOKEN=123:old\nTG_ADMIN_IDS=12\n',
                                          'TG_BOT_TOKEN=456:new; TG_ADMIN_IDS=56')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('TG_BOT_TOKEN=456:new', path.read_text())
            self.assertIn('TG_ADMIN_IDS=56', path.read_text())

    def test_restart_failure_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, path = self.run_setup(tmp, 'TG_BOT_TOKEN=123:abc\nTG_ADMIN_IDS=12\n', fail_restart=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SUCCESS', result.stdout)

    def test_launcher_separates_runtime_and_passes_exact_commit_and_args(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            runtime = base / 'runtime'
            runtime.mkdir()
            (runtime / 'keep').write_text('data')
            source = base / 'source'
            source.mkdir()
            (source / '.git').mkdir()
            (source / 'install.sh').write_text('printf "%s\\n" "$@" > "' + tmp + '/args"\n')
            mock = base / 'mock'
            mock.mkdir()
            commit = 'a' * 40
            (mock / 'git').write_text('#!/bin/bash\ncase "$3" in\nstatus|fetch|checkout) exit 0;;\nrev-parse) echo ' + commit + ';;\nesac\n')
            (mock / 'git').chmod(0o755)
            env = dict(os.environ, PATH=str(mock) + ':' + os.environ['PATH'], PGW_SRC_DIR=str(source), PGW_COMMIT=commit)
            result = subprocess.run(['bash', str(ROOT / 'quick-install.sh'), '--setup-tgbot'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((base / 'args').read_text().strip(), '--setup-tgbot')
            self.assertEqual((runtime / 'keep').read_text(), 'data')
            self.assertIn('PGW_SRC_DIR:-/opt/5gpn-source', (ROOT / 'quick-install.sh').read_text())


if __name__ == '__main__':
    unittest.main()
