"""--uninstall removes everything simcard-dns put on the host.

The real do_uninstall runs against a temporary filesystem: production
absolute prefixes are redirected in a copy of the sources, and service,
certificate and network commands are mocks. Certificates, backups and Go are
removed only when the user answers yes to their own question.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIMITS_BLOCK = ('# simcard-dns-limits\n* soft nofile 1048576\n* hard nofile 1048576\n'
                'root soft nofile 1048576\nroot hard nofile 1048576\n')


class UninstallCompleteTests(unittest.TestCase):
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
        for p in [self.source / 'install.sh', *self.source.glob('lib/*')]:
            if p.suffix not in ('.sh', '.py', '.template'):
                continue
            # One pass, so a temp dir under /var (macOS) is not rewritten twice.
            p.write_text(re.sub(r'(/opt/|/etc/|/var/|/usr/local/|/run/lock/)',
                                lambda m: str(self.fs) + m.group(1), p.read_text()))
        self.bin = self.root / 'mockbin'
        self.bin.mkdir()
        log = '#!/bin/bash\nprintf "%s %s\\n" "$(basename "$0")" "$*" >> "$TEST_ROOT/events"\n'
        for command in ('systemctl', 'userdel', 'wg-quick', 'iptables', 'iptables-restore', 'iptables-save', 'sysctl'):
            self.mock(command, log)
        self.mock('ip', log + '[[ "$2" != del ]]\n')  # `ip rule del` loop must end
        self.mock('nft', log)
        self.mock('certbot', log)
        self.env = dict(os.environ, TEST_ROOT=str(self.root),
                        PATH=f'{self.bin}:' + os.environ['PATH'], TMPDIR=str(self.root / 'tmp'))
        (self.root / 'tmp').mkdir()
        (self.source / 'runner.sh').write_text('''#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/install.sh"
set_exit() { echo "set_exit $*" >> "$TEST_ROOT/events"; }
do_uninstall
''')
        self.populate()

    def mock(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def put(self, path, text='x\n', mode=0o644):
        p = self.fs / path.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)

    def exists(self, path):
        return (self.fs / path.lstrip('/')).exists()

    def read(self, path):
        return (self.fs / path.lstrip('/')).read_text()

    def populate(self):
        sd = '/etc/systemd/system/'
        for unit in ('mosdns.service', 'dot-gate.service', 'sniproxy.service', 'wa-shim.service',
                     'quic-proxy.service', 'simcard-dns-tgbot.service', 'simcard-dns-exit.service',
                     'simcard-dns-ios-profile.socket', 'simcard-dns-ios-profile@.service',
                     'simcard-dns-mihomo@.service', 'simcard-dns-geo-update.service',
                     'simcard-dns-geo-update.timer', 'update-mosdns-rules.service',
                     'update-mosdns-rules.timer', 'mosdns.service.d/override.conf',
                     'quic-proxy.service.d/limits.conf', 'unrelated.service'):
            self.put(sd + unit)
        self.put(sd + 'disable-transparent-huge-pages.service',
                 "ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'\n")
        for path in ('/opt/simcard-dns/bin/simcard-dns', '/opt/simcard-dns/etc/.domain',
                     '/opt/simcard-dns/.installed-commit', '/etc/simcard-dns/rules.conf',
                     '/etc/simcard-dns/cloudflare.ini', '/etc/mosdns/config.yaml', '/etc/sniproxy.conf',
                     '/usr/local/bin/simcard-dns', '/usr/local/bin/simcard-dns-apply-exit.sh',
                     '/usr/local/bin/simcard-dns-open-cert-http.sh', '/usr/local/bin/simcard-dns-restore-firewall.sh',
                     '/usr/local/bin/update-mosdns-rules.sh', '/usr/local/bin/mosdns', '/usr/local/sbin/sniproxy',
                     '/usr/local/bin/unrelated-tool',
                     '/etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh',
                     '/etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh',
                     '/etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh',
                     '/var/lib/simcard-dns/tgbot-state.json', '/var/lib/simcard-dns-quic/remote-dns',
                     '/var/log/simcard-dns-install.log', '/run/lock/simcard-dns-routing.lock',
                     '/opt/simcard-dns-source/install.sh', '/opt/simcard-dns-source.backup-20261018T000000Z.ab/source/x',
                     '/opt/simcard-dns-source.staging.cd/x', '/opt/5gpn-source/install.sh', '/opt/5gpn/.install-attempt',
                     '/etc/sysctl.d/99-simcard-dns.conf', '/etc/modules-load.d/simcard-dns-net.conf',
                     '/etc/systemd/journald.conf.d/99-simcard-dns.conf', '/etc/profile.d/go.sh',
                     '/var/lib/systemd/timers/stamp-simcard-dns-geo-update.timer',
                     '/var/backups/simcard-dns/upgrade.x/config-code.tar.gz', '/usr/local/go/bin/go'):
            self.put(path)
        self.put('/etc/security/limits.conf', '# site limit\n@users soft nproc 100\n' + LIMITS_BLOCK)
        self.put('/etc/sysctl.conf', '# disabled by simcard-dns (see 99-simcard-dns.conf): vm.swappiness=10\nnet.core.somaxconn=1024\n')
        self.put('/etc/letsencrypt/renewal/simcard-dns-wildcard.conf',
                 'dns_cloudflare_credentials = /etc/simcard-dns/cloudflare.ini\n')
        self.put('/etc/letsencrypt/renewal/dot.example.net.conf',
                 'pre_hook = /usr/local/bin/simcard-dns-open-cert-http.sh\n')
        self.put('/etc/letsencrypt/renewal/someone-else.example.org.conf', 'authenticator = webroot\n')
        # Include paths as the (redirected) installer would have written them.
        conf_dir = str(self.fs) + '/etc/simcard-dns'
        self.put('/etc/nftables.conf', f'flush ruleset\ninclude "{conf_dir}/geo-allow.nft"\n'
                 'table inet filter { chain input { ct state established,related accept\n        jump geo_gate\n } }\n'
                 f'include "{conf_dir}/pgw-exit.nft"\n')

    def run_uninstall(self, answers):
        return subprocess.run(['bash', str(self.source / 'runner.sh')], input=answers, text=True,
                              capture_output=True, env=self.env, timeout=60)

    def events(self):
        p = self.root / 'events'
        return p.read_text() if p.exists() else ''

    def test_full_removal_with_every_optional_item(self):
        result = self.run_uninstall('y\ny\ny\ny\n')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('Uninstall completed', result.stdout + result.stderr)
        for gone in ('/opt/simcard-dns', '/etc/simcard-dns', '/etc/mosdns', '/etc/sniproxy.conf',
                     '/usr/local/bin/simcard-dns', '/usr/local/bin/simcard-dns-apply-exit.sh',
                     '/usr/local/bin/simcard-dns-open-cert-http.sh', '/usr/local/bin/simcard-dns-restore-firewall.sh',
                     '/usr/local/bin/update-mosdns-rules.sh', '/usr/local/bin/mosdns', '/usr/local/sbin/sniproxy',
                     '/etc/systemd/system/mosdns.service', '/etc/systemd/system/mosdns.service.d',
                     '/etc/systemd/system/quic-proxy.service.d', '/etc/systemd/system/simcard-dns-tgbot.service',
                     '/etc/systemd/system/simcard-dns-mihomo@.service', '/etc/systemd/system/update-mosdns-rules.timer',
                     '/etc/systemd/system/simcard-dns-geo-update.timer',
                     '/etc/systemd/system/disable-transparent-huge-pages.service',
                     '/etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh',
                     '/etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh',
                     '/etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh',
                     '/var/lib/simcard-dns', '/var/lib/simcard-dns-quic', '/var/log/simcard-dns-install.log',
                     '/run/lock/simcard-dns-routing.lock', '/opt/simcard-dns-source',
                     '/opt/simcard-dns-source.backup-20261018T000000Z.ab', '/opt/simcard-dns-source.staging.cd',
                     '/opt/5gpn-source', '/opt/5gpn', '/etc/sysctl.d/99-simcard-dns.conf',
                     '/etc/modules-load.d/simcard-dns-net.conf', '/etc/systemd/journald.conf.d/99-simcard-dns.conf',
                     '/var/lib/systemd/timers/stamp-simcard-dns-geo-update.timer',
                     '/var/backups/simcard-dns', '/usr/local/go', '/etc/profile.d/go.sh'):
            self.assertFalse(self.exists(gone), gone)
        # Other software's files are untouched.
        for kept in ('/etc/systemd/system/unrelated.service', '/usr/local/bin/unrelated-tool',
                     '/etc/letsencrypt/renewal/someone-else.example.org.conf'):
            self.assertTrue(self.exists(kept), kept)
        self.assertEqual(self.read('/etc/security/limits.conf'), '# site limit\n@users soft nproc 100\n')
        self.assertEqual(self.read('/etc/sysctl.conf'), 'vm.swappiness=10\nnet.core.somaxconn=1024\n')
        self.assertNotIn('simcard-dns', self.read('/etc/nftables.conf'))
        self.assertNotIn('geo_gate', self.read('/etc/nftables.conf'))
        events = self.events()
        self.assertIn('certbot delete --cert-name simcard-dns-wildcard --non-interactive', events)
        self.assertIn('certbot delete --cert-name dot.example.net --non-interactive', events)
        self.assertNotIn('someone-else', events)
        self.assertIn('systemctl restart systemd-journald', events)
        self.assertIn('userdel pxout', events)

    def test_optional_items_are_kept_when_declined(self):
        result = self.run_uninstall('y\nn\nn\nn\n')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse(self.exists('/opt/simcard-dns'))
        self.assertFalse(self.exists('/var/lib/simcard-dns'))
        self.assertTrue(self.exists('/var/backups/simcard-dns/upgrade.x/config-code.tar.gz'))
        self.assertTrue(self.exists('/usr/local/go/bin/go'))
        self.assertTrue(self.exists('/etc/profile.d/go.sh'), 'go stays on PATH when Go is kept')
        self.assertNotIn('certbot delete', self.events())
        out = result.stdout + result.stderr
        self.assertIn('Certificates kept', out)
        self.assertIn('Backups kept', out)

    def test_cancel_changes_nothing(self):
        result = self.run_uninstall('n\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.exists('/opt/simcard-dns/bin/simcard-dns'))
        self.assertTrue(self.exists('/etc/systemd/system/mosdns.service'))
        self.assertEqual(self.events(), '')

    def test_real_old_install_is_not_deleted(self):
        self.put('/opt/5gpn/bin/5gpn-ctl')
        result = self.run_uninstall('y\nn\nn\nn\n')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(self.exists('/opt/5gpn/bin/5gpn-ctl'))


if __name__ == '__main__':
    unittest.main()
