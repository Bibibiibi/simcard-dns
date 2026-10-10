import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class DNSTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.tmp.name)
        self.dns = self.base / 'dns'
        self.dns.mkdir()
        mock = self.base / 'bin'
        mock.mkdir()
        (mock / 'systemctl').write_text('''#!/bin/bash
if [[ "$1" == restart ]]; then
  echo restart >> "$TEST_BASE/restarts"
  if [[ -f "$TEST_BASE/fail" ]]; then rm "$TEST_BASE/fail"; exit 1; fi
fi
exit 0
''')
        (mock / 'mosdns').write_text('#!/bin/sh\nexit "${VALIDATE_RC:-0}"\n')
        for p in mock.iterdir():
            p.chmod(0o755)
        (self.dns / 'config.yaml.template').write_text((ROOT / 'lib/mosdns.yaml.template').read_text())
        for name in ('gfwlist.txt', 'chinalist.txt'):
            (self.dns / name).write_text('example.org\n')
        (self.dns / '.public_ip').write_text('192.0.2.1\n')
        (self.dns / 'config.yaml').write_text('OLD-CONFIG\n')
        (self.dns / 'domain-overrides.conf').write_text('example.org=proxy\ndirect.example=direct\nblock.example=block\n')
        self.env = dict(os.environ, PGW_MOSDNS_DIR=str(self.dns), PGW_ROUTING_LOCK_FILE=str(self.base / 'lock'),
                        TEST_BASE=str(self.base), PATH=str(mock) + ':' + os.environ['PATH'])

    def tearDown(self):
        self.tmp.cleanup()

    def run_update(self, mode='--offline'):
        return subprocess.run(['bash', str(ROOT / 'lib/update-rules.sh'), mode], env=self.env,
                              capture_output=True, text=True)

    def test_override_snapshot_and_private_precedence(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dns / 'override-proxy.txt').read_text(), 'example.org\n')
        self.assertEqual((self.dns / 'override-direct.txt').read_text(), 'direct.example\n')
        self.assertEqual((self.dns / 'override-block.txt').read_text(), 'block.example\n')
        config = (self.dns / 'config.yaml').read_text()
        self.assertNotIn('.rules-stage.', config)
        private = config.split('- tag: private_client')[1].split('- tag: public_client')[0]
        self.assertLess(private.index('$override_proxy_domains'), private.index('$china_domains'))
        self.assertLess(private.index('$override_block_domains'), private.index('$override_proxy_domains'))
        public = config.split('- tag: public_client')[1].split('- tag: main_sequence')[0]
        self.assertNotIn('override_', public)

    def test_restart_failure_restores_entire_snapshot(self):
        before = {p.name: p.read_bytes() for p in self.dns.iterdir()}
        (self.base / 'fail').touch()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        after = {p.name: p.read_bytes() for p in self.dns.iterdir()}
        self.assertEqual(before, after)
        self.assertEqual((self.base / 'restarts').read_text().count('restart'), 2)

    def test_validation_failure_does_not_publish(self):
        self.env['VALIDATE_RC'] = '1'
        before = {p.name: p.read_bytes() for p in self.dns.iterdir()}
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.dns.iterdir()})
        self.assertFalse((self.base / 'restarts').exists())

    def test_legacy_missing_public_ip_and_failed_route_uses_fallback(self):
        (self.dns / '.public_ip').unlink()
        mock = self.base / 'bin/ip'
        mock.write_text('#!/bin/sh\nexit 1\n')
        mock.chmod(0o755)
        result = self.run_update('--render-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('127.0.0.1', (self.dns / 'config.yaml').read_text())
        self.assertFalse((self.base / 'restarts').exists())

    def test_render_only_never_restarts(self):
        result = self.run_update('--render-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'restarts').exists())

    def test_offline_still_restarts_for_standalone_domain_changes(self):
        result = self.run_update('--offline')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'restarts').read_text(), 'restart\n')

    def test_invalid_offline_cache_reports_which_cache_without_contents(self):
        for name, label in (('gfwlist.txt', 'GFWList'), ('chinalist.txt', 'ChinaList')):
            for data in (None, '', 'example.org\n\n', '# comment\nexample.org\n',
                         'example.org\r\n', '<html>SECRET-SENTINEL</html>\n'):
                with self.subTest(name=name, data=data):
                    path = self.dns / name
                    if data is None:
                        path.unlink()
                    else:
                        path.write_text(data)
                    before = {p.name: p.read_bytes() for p in self.dns.iterdir()}
                    result = self.run_update()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f'Offline {label} cache is missing or invalid', result.stderr)
                    self.assertNotIn('SECRET-SENTINEL', result.stderr)
                    self.assertEqual(before, {p.name: p.read_bytes() for p in self.dns.iterdir()})
                    self.assertFalse((self.base / 'restarts').exists())
                    path.write_text('example.org\n')

    def test_empty_and_comment_only_local_extras_do_not_fail(self):
        for data in ('', '\n', '# comment\n', 'example.net\n\n', 'example.net'):
            with self.subTest(data=data):
                (self.dns / 'gfwlist-extra-local.txt').write_text(data)
                result = self.run_update()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_override_never_publishes(self):
        (self.dns / 'domain-overrides.conf').write_text('broken=unknown\n')
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.dns / 'config.yaml').read_text(), 'OLD-CONFIG\n')


if __name__ == '__main__':
    unittest.main()
