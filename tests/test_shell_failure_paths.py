"""Failure injection: no real firewall, package manager or service changes."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def functions(path):
    text = (ROOT / path).read_text()
    if path.endswith('update-rules.sh'):
        # Keep only the function library; the updater's executable transaction
        # begins at the routing-lock setup in current revisions.
        marker = 'lock_file="${PGW_ROUTING_LOCK_FILE:-/run/lock/5gpn-routing.lock}"'
        if marker in text:
            text = text[:text.index(marker)]
        else:
            text = text[:text.index('echo "[$(date)] Starting mosdns')]
    return text


class ShellFailures(unittest.TestCase):
    def bash(self, script):
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True)

    def test_managed_failure_in_conditional(self):
        script = functions('lib/host-setup.sh') + '''
info() { :; }; ok() { echo FALSE_SUCCESS; }; warn() { echo "$*" >&2; }
ensure_proxy_user() { :; }; resolve_firewall_mode() { echo managed; }
detect_ssh_ports() { echo 22; }; apply_pgw_exit_rules() { :; }
firewall_managed_apply() { return 1; }
if setup_firewall; then exit 99; fi
'''
        result = self.bash(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('FALSE_SUCCESS', result.stdout)

    def test_port_failure(self):
        result = self.bash(functions('lib/host-setup.sh') + '''
info() { :; }; warn() { echo "$*" >&2; }
nft() { [[ "$1" == list ]]; }
if open_cert_http_port; then exit 99; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TCP/80', result.stderr)

    def test_prepare_failure_restores_services(self):
        result = self.bash(functions('lib/cert.sh') + '''
info() { :; }; warn() { echo "$*" >&2; }
systemctl() { echo "$*"; }
open_cert_http_port() { return 1; }
restore_reverse_proxy_firewall() { echo restored; }
if prepare_certbot_standalone; then exit 99; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('start sniproxy', result.stdout)
        self.assertIn('start wa-shim', result.stdout)
        self.assertIn('restored', result.stdout)

    def test_rule_failure_keeps_cache(self):
        for old in ('', 'example.com\n'):
            for kind in ('download', 'empty'):
                with self.subTest(old=old, kind=kind), tempfile.TemporaryDirectory() as tmp:
                    cache = pathlib.Path(tmp) / 'list'
                    cache.write_text(old)
                    result = self.bash(functions('lib/update-rules.sh') + f'''
RAW='{tmp}/raw'; FILE='{cache}'
wget() {{ {'return 1' if kind == 'download' else ': > "$2"'}; }}
parse_test() {{ : > "$FILE"; }}
update_domain_cache test URL RAW FILE parse_test
''')
                    self.assertEqual(result.returncode, 0 if old else 1, result.stderr)
                    self.assertEqual(cache.read_text(), old)

    def test_broken_installed_cli_fails_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / '5gpn-ctl'
            path.write_text((ROOT / 'install.sh').read_text())
            result = subprocess.run(['bash', str(path)], capture_output=True, text=True,
                                    env={'PATH': '/usr/bin:/bin', 'G5PNX_BOOTSTRAPPED': '1'})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('checkout', result.stderr)


if __name__ == '__main__':
    unittest.main()
