import base64
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TLD_SUFFIXES = ('cn', 'top', 'wang', 'xn--55qx5d', 'xn--fiqs8s', 'xn--io0a7i')
CHINA_DOMAINS = ('example.cn', 'sub.example.com', *TLD_SUFFIXES)


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
        (mock / 'wget').write_text('''#!/bin/bash
echo fetch >> "$TEST_BASE/fetches"
[[ "${ALLOW_FETCH:-0}" == 1 ]] || exit 99
case "$3" in
  */gfwlist.txt) cp "$TEST_BASE/gfw.raw" "$2";;
  */accelerated-domains.china.conf) cp "$TEST_BASE/china.raw" "$2";;
  *) exit 98;;
esac
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
                        PGW_DEFAULT_RULES_FILE=str(self.base / 'no-default-rules'),
                        # Never read the host's real routing rules (they may
                        # name remote rule-sets the updater would fetch).
                        PGW_RULES_FILE=str(self.base / 'no-user-rules'),
                        PGW_POLICY_MAP=str(self.base / 'no-policy-map'),
                        TEST_BASE=str(self.base), PATH=str(mock) + ':' + os.environ['PATH'])

    def tearDown(self):
        self.tmp.cleanup()

    def run_update(self, mode='--offline'):
        return subprocess.run(['bash', str(ROOT / 'lib/update-rules.sh'), mode], env=self.env,
                              capture_output=True, text=True)

    def prepare_online(self, raw=None):
        self.env['ALLOW_FETCH'] = '1'
        (self.base / 'gfw.raw').write_bytes(base64.b64encode(b'||example.org^\n'))
        if raw is None:
            raw = '# ChinaList fixture\n' + ''.join(
                f'server=/{domain}/114.114.114.114\n' for domain in CHINA_DOMAINS)
        (self.base / 'china.raw').write_text(raw)

    def test_chinalist_tlds_offline_and_render_only_preserve_every_byte(self):
        # Production cache includes these six formerly rejected suffixes. Include
        # duplicates/order and no final newline to prove offline never filters it.
        data = '\n'.join((*CHINA_DOMAINS, 'example.cn'))
        for mode in ('--offline', '--render-only'):
            with self.subTest(mode=mode):
                (self.base / 'restarts').unlink(missing_ok=True)
                (self.dns / 'chinalist.txt').write_text(data)
                result = self.run_update(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.dns / 'chinalist.txt').read_text(), data)
                self.assertFalse((self.base / 'fetches').exists())
                self.assertEqual((self.base / 'restarts').exists(), mode == '--offline')

    def test_online_chinalist_parser_and_cache_preserve_tlds(self):
        self.prepare_online()
        result = self.run_update('')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dns / 'chinalist.txt').read_text(),
                         ''.join(domain + '\n' for domain in sorted(CHINA_DOMAINS)))
        self.assertEqual((self.dns / 'chinalist.raw').read_bytes(),
                         (self.base / 'china.raw').read_bytes())
        self.assertEqual((self.base / 'fetches').read_text(), 'fetch\nfetch\n')
        self.assertNotIn('keeping valid previous', result.stderr)

    def test_online_failed_download_keeps_complete_chinalist_cache(self):
        data = '\n'.join(CHINA_DOMAINS) + '\n'
        (self.dns / 'chinalist.txt').write_text(data)
        result = self.run_update('')  # mock download fails, no real network
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ChinaList download/parse failed; keeping valid previous', result.stderr)
        self.assertEqual((self.dns / 'chinalist.txt').read_text(), data)

    def test_online_invalid_chinalist_never_publishes_partial_set(self):
        for bad in ('<html>SECRET-SENTINEL</html>\n',
                    'server=/bad name/114.114.114.114\n',
                    'server=/$(SECRET-SENTINEL)/114.114.114.114\n',
                    'server=/bad..example/114.114.114.114\n'):
            with self.subTest(bad=bad):
                # Mix a malformed extracted entry with a valid one: reject the
                # whole candidate, not just its bad entry. HTML-only is empty.
                raw = bad if bad.startswith('<') else 'server=/cn/114.114.114.114\n' + bad
                self.prepare_online(raw)
                for fallback in (True, False):
                    with self.subTest(fallback=fallback):
                        data = 'cn\nxn--fiqs8s\n' if fallback else ''
                        (self.dns / 'chinalist.txt').write_text(data)
                        (self.dns / 'chinalist.raw').write_text('old raw\n')
                        before = {p.name: p.read_bytes() for p in self.dns.iterdir()}
                        result = self.run_update('')
                        self.assertEqual(result.returncode == 0, fallback, result.stderr)
                        self.assertNotIn('SECRET-SENTINEL', result.stderr)
                        self.assertEqual((self.dns / 'chinalist.txt').read_text(), data)
                        self.assertEqual((self.dns / 'chinalist.raw').read_text(), 'old raw\n')
                        if not fallback:
                            self.assertEqual(before, {p.name: p.read_bytes() for p in self.dns.iterdir()})

    def test_tld_support_does_not_relax_local_extras_overrides_or_gfw_cache(self):
        (self.dns / 'gfwlist-extra-local.txt').write_text('cn\nexample.net\n')
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dns / 'gfwlist.txt').read_text(), 'example.net\nexample.org\n')
        (self.dns / 'domain-overrides.conf').write_text('cn=direct\n')
        self.assertNotEqual(self.run_update().returncode, 0)
        (self.dns / 'domain-overrides.conf').write_text('')
        (self.dns / 'gfwlist.txt').write_text('cn\n')
        self.assertNotEqual(self.run_update().returncode, 0)

    def test_override_snapshot_and_private_precedence(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dns / 'override-proxy.txt').read_text(), 'example.org\n')
        self.assertEqual((self.dns / 'override-direct.txt').read_text(), 'direct.example\n')
        self.assertEqual((self.dns / 'override-block.txt').read_text(), 'block.example\n')
        config = (self.dns / 'config.yaml').read_text()
        self.assertNotIn('.rules-stage.', config)
        proxied = config.split('- tag: proxy_client')[1].split('- tag: other_client')[0]
        self.assertLess(proxied.index('$override_proxy_domains'), proxied.index('$china_domains'))
        self.assertLess(proxied.index('$override_block_domains'), proxied.index('$override_proxy_domains'))
        other = config.split('- tag: other_client')[1].split('- tag: main_sequence')[0]
        self.assertNotIn('override_', other)

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
                         'example.org\r\n', '<html>SECRET-SENTINEL</html>\n',
                         ' cn\n', 'cn \n', 'bad name\n', 'bad\tname\n',
                         '.cn\n', 'cn.\n', 'bad..example\n', '-cn\n', 'cn-\n',
                         '*.cn\n', 'https://example.org\n', '$(SECRET-SENTINEL)\n',
                         'cn;SECRET-SENTINEL\n'):
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
                    if data:
                        expected_line = 2 if data == 'example.org\n\n' else 1
                        self.assertIn(f'entry at line {expected_line}', result.stderr)
                    self.assertFalse((self.base / 'fetches').exists())
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
