"""Hermetic upgrade behavior through the real run_install_step convention.

Production literals are redirected in temporary source copies before sourcing;
network/build/service boundaries are mocked, not the transaction or renderer.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UNITS = ('mosdns', 'sniproxy', 'quic-proxy', 'wa-shim', 'simcard-dns-tgbot', 'simcard-dns-mihomo@smart')


class UpgradeTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fs = self.root / 'fs'
        self.source = self.root / 'source'
        self.source.mkdir()
        shutil.copytree(ROOT / 'lib', self.source / 'lib')
        script = (ROOT / 'install.sh').read_text().split('\ncase "${1:-}" in\n')[0]
        (self.source / 'install.sh').write_text(script)
        # Every production absolute filesystem prefix in sourced scripts is
        # redirected. /proc is read-only FD introspection used by routing_lock.
        for p in [self.source / 'install.sh', *self.source.glob('lib/*')]:
            if p.suffix not in ('.sh', '.py', '.template'):
                continue
            text = p.read_text()
            for prefix in ('/opt/', '/etc/', '/var/', '/usr/local/', '/run/lock/'):
                text = text.replace(prefix, str(self.fs) + prefix)
            p.write_text(text)
        self.bin = self.root / 'mockbin'
        self.bin.mkdir()
        self.put('/etc/mosdns/.remote_dns', '1.1.1.1\n')
        self.put('/etc/mosdns/.local_dns', '119.29.29.29\n')
        for f in ('config.yaml', 'config.yaml.template', 'gfwlist.txt', 'chinalist.txt',
                  'override-direct.txt', 'override-proxy.txt', 'override-block.txt'):
            self.put('/etc/mosdns/' + f, 'old-' + f + '\n')
        self.put('/etc/mosdns/domain-overrides.conf', 'example.org=proxy\n')
        self.put('/etc/mosdns/.public_ip', '192.0.2.1\n')
        self.put('/etc/simcard-dns/rules.conf', 'DOMAIN-SUFFIX,example.org,direct\n')
        self.put('/etc/simcard-dns/rules-default.conf', 'old-default\n')
        # A complete existing installation maps all shipped default categories.
        categories = {line.rsplit(',', 1)[-1].strip() for line in
                      (ROOT / 'lib/rules-default.conf').read_text().splitlines()
                      if line and not line.startswith('#')}
        self.put('/etc/simcard-dns/policy-map.conf',
                 ''.join(f'{category}=direct\n' for category in sorted(categories)))
        self.put('/etc/simcard-dns/exits/smart.yaml', 'old-smart\n')
        self.put('/etc/simcard-dns/exits/smart.type', 'router\n')
        self.put('/etc/simcard-dns/rulesets/existing', 'old-cache\n')
        self.put('/opt/simcard-dns/etc/current-exit', 'smart\n')
        self.put('/opt/simcard-dns/etc/mihomo/smart/runtime', 'old-runtime\n')
        self.put('/opt/simcard-dns/bin/quic-proxy', 'old-binary\n', 0o755)
        self.put('/opt/simcard-dns/bin/mihomo', '#!/bin/bash\n[[ "$FAIL" != smart_validation ]]\n', 0o755)
        self.put('/var/lib/simcard-dns-quic/remote-dns', 'old-dns\n')
        self.put('/usr/local/bin/mosdns', '#!/bin/bash\n[[ "$FAIL" != renderer ]]\n', 0o755)
        self.put('/usr/local/bin/update-mosdns-rules.sh', 'old-updater\n', 0o755)
        self.put('/etc/systemd/system/quic-proxy.service', 'old-unit\n')
        self.put('/etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh', 'old-hook\n')
        self.state = self.root / 'states'
        self.state.mkdir()
        for i, unit in enumerate(UNITS):
            (self.state / unit).write_text('active' if i % 2 == 0 else 'inactive')
            (self.state / (unit + '.enabled')).write_text('enabled' if i < 3 else 'disabled')
        self.mock('systemctl', '''#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$TEST_ROOT/events"
unit="${*: -1}"; unit="${unit%.service}"
case "$1" in
 is-active) [[ "$(cat "$TEST_ROOT/states/$unit" 2>/dev/null)" == active ]];;
 is-enabled) [[ "$(cat "$TEST_ROOT/states/$unit.enabled")" == enabled ]];;
 restart)
   if [[ "$FAIL" == restart && ! -f "$TEST_ROOT/failed" ]]; then
     touch "$TEST_ROOT/failed"; echo inactive > "$TEST_ROOT/states/$unit"; exit 1
   fi
   echo -n active > "$TEST_ROOT/states/$unit";;
 daemon-reload|cat) :;;
 enable|disable)
   # Only the DoT gate may change enablement: upgrades that move mosdns off
   # public :853 must enable it, and a rollback must stop it again.
   [[ "$unit" == dot-gate ]] || { echo "unexpected service mutation $*" >&2; exit 97; }
   # In these fixtures the gate did not exist before the upgrade, so
   # disabling it returns to "not installed" (no state at all).
   if [[ "$1" == enable ]]; then echo -n enabled > "$TEST_ROOT/states/dot-gate.enabled"
   else rm -f "$TEST_ROOT/states/dot-gate" "$TEST_ROOT/states/dot-gate.enabled"; fi;;
 *) echo "unexpected service mutation $*" >&2; exit 97;;
esac
''')
        self.mock('go', '''#!/bin/bash
set -eu
# A distinct open-file description must fail to acquire the parent's lock.
if flock -n "$PGW_ROUTING_LOCK_FILE" -c true; then exit 98; fi
echo held >> "$TEST_ROOT/lock-proof"
[[ "$FAIL" != build ]] || exit 31
printf 'new-quic\n' > quic-proxy
''')
        for command in ('curl', 'wget', 'useradd', 'iptables', 'ip'):
            self.mock(command, '#!/bin/bash\necho forbidden >&2\nexit 99\n')
        self.env = dict(os.environ, TEST_ROOT=str(self.root), FAIL='',
                        PGW_ROUTING_LOCK_FILE=str(self.root / 'routing.lock'),
                        PATH=f'{self.bin}:{self.fs}/usr/local/bin:' + os.environ['PATH'],
                        TMPDIR=str(self.root / 'tmp'))
        (self.root / 'tmp').mkdir()
        self.runner = self.source / 'runner.sh'
        self.runner.write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
SCRIPT_PATH="$SCRIPT_DIR/install.sh"
INSTALL_LOG="$TEST_ROOT/upgrade.log"
# Never run download/install helpers or any interactive routing apply helper.
install_mosdns_binary() { printf 'new-mosdns\\n' > "${TEST_ROOT}/fs/usr/local/bin/mosdns"; }
regen_smart() { echo forbidden-regen >&2; exit 99; }
init_install_log
run_install_step upgrade upgrade_code
printf 'completed\\n'
''')

    def put(self, path, text, mode=0o640):
        p = self.fs / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def mock(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def snapshot(self):
        return {str(p.relative_to(self.fs)): (p.read_bytes(), p.stat().st_mode & 0o777)
                for p in self.fs.rglob('*') if p.is_file()}

    def states(self):
        return {p.name: p.read_text() for p in self.state.iterdir()}

    def run_upgrade(self, fail=''):
        self.env['FAIL'] = fail
        result = subprocess.run(['bash', str(self.runner)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        log = self.root / 'upgrade.log'
        self.detail = result.stderr + (log.read_text() if log.exists() else '')
        # No leaked lock after success or rollback.
        self.assertEqual(subprocess.run(['flock', '-n', self.env['PGW_ROUTING_LOCK_FILE'],
                                         '-c', 'true']).returncode, 0)
        return result

    def assert_rollback(self, fail):
        before, states = self.snapshot(), self.states()
        result = self.run_upgrade(fail)
        self.assertNotEqual(result.returncode, 0, self.detail)
        self.assertNotIn('completed', result.stdout)
        self.assertNotIn('unbound variable', self.detail)
        self.assertEqual(before, self.snapshot(), self.detail)
        self.assertEqual(states, self.states(), self.detail)
        self.assertFalse(list(self.fs.glob('opt/simcard-dns/.upgrade-*')))

    def test_renderer_failure_rolls_back_through_actual_step(self):
        self.assert_rollback('renderer')

    def test_build_failure_rolls_back_and_cleans_build_directory(self):
        self.assert_rollback('build')
        self.assertIn('stage=quic-build exit=31', self.detail)
        self.assertEqual((self.root / 'lock-proof').read_text(), 'held\n')
        # Offline rendering must not restart mosdns before the rest of the
        # upgrade transaction succeeds; rollback performs the only recovery
        # restart for a failure after publication.
        events = (self.root / 'events').read_text().splitlines()
        self.assertEqual(sum(line == 'restart mosdns.service' for line in events), 1)

    def test_restart_failure_restores_files_and_active_disabled_services(self):
        self.assert_rollback('restart')
        # The rollback must release public :853 for the restored mosdns.
        self.assertIn('disable --now dot-gate.service', (self.root / 'events').read_text())

    def test_upgrade_enables_the_dot_gate_after_mosdns(self):
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, self.detail)
        events = (self.root / 'events').read_text().splitlines()
        self.assertIn('enable dot-gate.service', events)
        self.assertLess(events.index('restart mosdns.service'), events.index('restart dot-gate.service'))
        self.assertTrue((self.fs / 'etc/systemd/system/dot-gate.service').exists())
        self.assertTrue((self.fs / 'opt/simcard-dns/bin/dot-gate.py').exists())

    def test_smart_validation_failure_restores_runtime_and_cache(self):
        self.assert_rollback('smart_validation')

    def test_invalid_offline_rule_cache_reports_failure_and_rolls_back(self):
        (self.fs / 'etc/simcard-dns/rules.conf').unlink()
        self.put('/etc/mosdns/.remote_dns', '22.22.22.22\n')
        self.put('/etc/mosdns/.local_dns', '101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29\n')
        # GFWList is no longer required; an unusable ChinaList cache is what
        # must stop the offline DNS rebuild and roll the upgrade back.
        self.put('/etc/mosdns/gfwlist.txt', '')
        self.put('/etc/mosdns/chinalist.txt', '')
        before = self.snapshot()
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0, self.detail)
        self.assertIn('Offline ChinaList cache is missing or invalid', self.detail)
        self.assertIn('stage=offline-dns exit=1', self.detail)
        self.assertEqual(before, self.snapshot(), self.detail)
        # Rollback restarts the services that were active before the
        # transaction, even when validation failed before publication.
        self.assertIn('restart mosdns.service',
                      (self.root / 'events').read_text() if (self.root / 'events').exists() else '')

    def test_invalid_dns_preflight_never_changes_managed_files(self):
        for name in ('.remote_dns', '.local_dns'):
            with self.subTest(name=name):
                path = self.fs / 'etc/mosdns' / name
                old = path.read_text()
                path.write_text('https://dns.example/dns-query\n')
                before = self.snapshot()
                result = self.run_upgrade()
                self.assertNotEqual(result.returncode, 0, self.detail)
                self.assertIn('stage=dns-preflight exit=1', self.detail)
                self.assertEqual(before, self.snapshot())
                self.assertFalse((self.root / 'events').exists())
                self.assertFalse(list(self.fs.glob('opt/simcard-dns/.upgrade-*')))
                path.write_text(old)

    def test_success_preserves_stopped_enabled_and_active_disabled_states(self):
        states = self.states()
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, self.detail)
        # Every existing unit keeps its state; mosdns was active, so the new
        # DoT gate (which now owns public :853) is enabled and running.
        self.assertEqual(states['mosdns'], 'active')
        self.assertEqual(dict(states, **{'dot-gate': 'active', 'dot-gate.enabled': 'enabled'}), self.states())
        self.assertIn('completed', result.stdout)
        self.assertEqual((self.root / 'lock-proof').read_text(), 'held\n')
        events = (self.root / 'events').read_text()
        for unit in ('sniproxy', 'wa-shim', 'simcard-dns-mihomo@smart'):
            self.assertNotIn('restart ' + unit + '.service', events)
        self.assertIn('restart simcard-dns-tgbot.service', events)
        self.assertEqual([line for line in events.splitlines() if line.startswith('restart mosdns')],
                         ['restart mosdns.service'])
        self.assertEqual((self.fs / 'var/lib/simcard-dns-quic/remote-dns').read_text(), '1.1.1.1\n')
        self.assertFalse(list(self.fs.glob('opt/simcard-dns/.upgrade-*')))

    def test_active_smart_upgrade_does_not_apply_routes_or_migrate_legacy_units(self):
        (self.state / 'simcard-dns-mihomo@smart').write_text('active')
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, self.detail)
        events = (self.root / 'events').read_text()
        self.assertEqual(events.count('restart simcard-dns-mihomo@smart.service'), 1)
        self.assertNotIn('singbox', events)
        self.assertEqual((self.fs / 'opt/simcard-dns/etc/current-exit').read_text(), 'smart\n')


if __name__ == '__main__':
    unittest.main()
