"""Hermetic raw entrypoint boundaries; no real package/network/runtime writes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40


class RawEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.calls = self.base / 'calls'
        self.runtime = self.base / 'runtime'
        # Disable only the root gate in this isolated source copy (CI is nonroot).
        self.script = (ROOT / 'install.sh').read_text().replace(
            'if [[ $EUID -ne 0 ]]; then', 'if false; then').replace(
            'BASE_DIR="/opt/simcard-dns"', f'BASE_DIR="{self.runtime}"').replace('RUNTIME_DIR="/opt/simcard-dns"', f'RUNTIME_DIR="{self.runtime}"')
        # A closed PATH makes missing-git tests independent of host packages.
        for name in ('bash', 'awk', 'mktemp', 'rm', 'chmod', 'cat', 'dirname', 'basename', 'realpath', 'stat', 'mkdir', 'cp', 'mv', 'date'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.mock('git', 'echo "git:$*" >> "$CALLS"\ncase "$1" in\nls-remote) [[ "${FAIL_REF:-0}" == 0 ]] || exit 17; echo "${SHA_RESULT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa} refs/heads/main";;\nclone) [[ "${FAIL_DOWNLOAD:-0}" == 0 ]] || exit 22; mkdir -p "${@: -1}/.git"; cp "$TMPDIR/fixture" "${@: -1}/install.sh";;\n-C) [[ "$3" != rev-parse ]] || echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;;\nesac\n')
        (self.base / 'fixture').write_text('printf \'launcher:<%s>\\n\' "$@" >> "$CALLS"\necho "commit:$PGW_COMMIT" >> "$CALLS"\nexit "${LAUNCHER_RC:-0}"\n')
        self.env = dict(os.environ, PATH=str(self.bin), CALLS=str(self.calls),
                        TMPDIR=str(self.base), PGW_SRC_DIR=str(self.base / "source"))
        self.env.pop('PGW_COMMIT', None)

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)

    def run_raw(self, *args, standalone=False, **env):
        if standalone:
            path = self.base / 'install.sh'
            path.write_text(self.script)
            cmd = [str(self.bin / 'bash'), str(path), *args]
            data = ''
        else:
            cmd = [str(self.bin / 'bash'), '-s', '--', *args]
            data = self.script
        result = subprocess.run(cmd, input=data, text=True, capture_output=True,
                                cwd=self.base, env=dict(self.env, **env), timeout=10)
        self.assertEqual(list(self.base.glob('simcard-dns-quick.*')), [], result.stderr)
        return result

    def log(self):
        return self.calls.read_text() if self.calls.exists() else ''

    def test_pipe_pins_and_preserves_argument_boundaries(self):
        result = self.run_raw('--status', 'two words')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'checkout --quiet --detach {SHA}', self.log())
        self.assertIn('launcher:<two words>', self.log())
        self.assertIn(f'commit:{SHA}', self.log())

    def test_explicit_commit_skips_resolution(self):
        result = self.run_raw(PGW_COMMIT=SHA.upper())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('git:ls-remote', self.log())
        self.assertIn(f'checkout --quiet --detach {SHA}', self.log())

    def test_resolution_and_download_failures_never_launch(self):
        for env in ({'FAIL_REF': '1'}, {'SHA_RESULT': 'bad'},
                    {'PGW_COMMIT': 'bad'}, {'FAIL_DOWNLOAD': '1'}):
            with self.subTest(env=env):
                self.calls.unlink(missing_ok=True)
                result = self.run_raw(**env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('launcher:', self.log())

    def test_launcher_failure_status_and_cleanup(self):
        self.assertEqual(self.run_raw(LAUNCHER_RC='37').returncode, 37)

    def test_standalone_file_bootstraps(self):
        result = self.run_raw('--help', standalone=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('launcher:<--help>', self.log())

    def test_pipe_ignores_working_directory_libraries(self):
        shutil.copytree(ROOT / 'lib', self.base / 'lib')
        (self.base / 'lib/common.sh').write_text('echo UNSAFE >&2; exit 91\n')
        result = self.run_raw()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNSAFE', result.stderr)
        self.assertIn('launcher:', self.log())

    def test_full_checkout_help_does_not_bootstrap(self):
        shutil.copytree(ROOT / 'lib', self.base / 'lib')
        result = self.run_raw('--help', standalone=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage:', result.stdout)
        self.assertEqual(self.log(), '')

    def test_offline_management_uses_existing_cli(self):
        ctl = self.runtime / 'bin/simcard-dns'
        ctl.parent.mkdir(parents=True)
        ctl.write_text('printf "management:<%s>\\n" "$@"\n')
        result = self.run_raw('--status', FAIL_REF='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('management:<--status>', result.stdout)
        self.assertEqual(self.log(), '')

    def test_missing_git_installs_using_supported_package_managers(self):
        git_body = (self.bin / 'git').read_text()
        for manager in ('apt-get', 'dnf', 'yum'):
            with self.subTest(manager=manager):
                (self.runtime / '.installed-commit').unlink(missing_ok=True)
                (self.bin / 'git').unlink(missing_ok=True)
                self.calls.unlink(missing_ok=True)
                template = self.base / 'git-template'
                template.write_text(git_body)
                self.mock(manager, '''echo "package:$*" >> "$CALLS"
[[ "$1" != install ]] || {
 cat "$TMPDIR/git-template" > "$TMPDIR/bin/git"
 chmod 755 "$TMPDIR/bin/git"
}
''')
                result = self.run_raw()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('package:install', self.log())
                self.assertIn('launcher:', self.log())
                (self.bin / manager).unlink()

    def test_missing_git_package_failure_stops_before_download(self):
        (self.bin / 'git').unlink()
        self.mock('apt-get', 'exit 8\n')
        result = self.run_raw()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('launcher:', self.log())


if __name__ == '__main__':
    unittest.main()
