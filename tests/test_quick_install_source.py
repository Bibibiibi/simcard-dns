"""Real Git source preservation, isolated paths and no deployment/network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "remote"
        self.repo.mkdir()
        self.git("init", "-q", str(self.repo))
        self.git("-C", str(self.repo), "config", "user.email", "test@example.org")
        self.git("-C", str(self.repo), "config", "user.name", "Test")
        (self.repo / "install.sh").write_text('printf "%s\\n" "$*" > "$TEST_BASE/called"\n')
        (self.repo / ".gitignore").write_text("ignored\n")
        self.git("-C", str(self.repo), "add", ".")
        self.git("-C", str(self.repo), "commit", "-qm", "fixture")
        self.sha = self.git("-C", str(self.repo), "rev-parse", "HEAD").strip()
        self.source = self.base / "source"
        self.git("clone", "-q", str(self.repo), str(self.source))
        self.runtime = self.base / "runtime"
        (self.runtime / "etc").mkdir(parents=True)
        (self.runtime / "etc/.domain").write_text("keep.example\n")
        (self.runtime / ".installed-commit").write_text("old\n")
        text = "set -euo pipefail\n" + (ROOT / "install.sh").read_text().split("bootstrap_install() (\n", 1)[1].split("\n)\n", 1)[0]
        text = text.replace('RUNTIME_DIR="/opt/5gpn"', f'RUNTIME_DIR="{self.runtime}"')
        text = text.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
        text = text.replace('https://github.com/${REPO}.git', str(self.repo))
        self.launcher = self.base / "quick.sh"
        self.launcher.write_text(text)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PGW_SRC_DIR=str(self.source), PGW_COMMIT=self.sha,
                        TEST_BASE=str(self.base), PATH=f"{self.bin}:{os.environ['PATH']}")

    def git(self, *args):
        return subprocess.check_output([GIT, *args], text=True, stderr=subprocess.DEVNULL)

    def run_launcher(self, **env):
        return subprocess.run(["bash", str(self.launcher)], env=dict(self.env, **env),
                              capture_output=True, text=True, input="", timeout=20,
                              start_new_session=True)

    def backups(self):
        return list(self.base.glob("source.backup-*/source"))

    def dirty(self):
        (self.source / "install.sh").write_text("manual edit\n")
        (self.source / "untracked").write_text("untracked\n")
        (self.source / "ignored").write_text("secret\n")

    def fake(self, command, code):
        path = self.bin / command
        path.write_text("#!/usr/bin/env bash\n" + code + "\n")
        path.chmod(0o755)

    def assert_runtime_untouched(self):
        self.assertEqual((self.runtime / "etc/.domain").read_text(), "keep.example\n")
        self.assertEqual((self.runtime / ".installed-commit").read_text(), "old\n")
        self.assertFalse((self.base / "called").exists())

    def test_dirty_real_git_and_upgrade(self):
        self.dirty()
        inode = self.source.stat().st_ino
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        backup, = self.backups()
        self.assertEqual(backup.stat().st_ino, inode)
        self.assertEqual(backup.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(backup.parent.stat().st_uid, os.geteuid())
        for name, data in (("install.sh", "manual edit\n"), ("untracked", "untracked\n"),
                           ("ignored", "secret\n")):
            self.assertEqual((backup / name).read_text(), data)
        self.assertEqual(self.git("-C", str(self.source), "rev-parse", "HEAD").strip(), self.sha)
        self.assertEqual((self.base / "called").read_text(), "--upgrade\n")
        self.assertEqual((self.runtime / "etc/.domain").read_text(), "keep.example\n")

    def test_clean_reused(self):
        inode = self.source.stat().st_ino
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual(self.source.stat().st_ino, inode)
        self.assertEqual(self.backups(), [])

    def test_ignored_only_archived(self):
        (self.source / "ignored").write_text("keep")
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual((self.backups()[0] / "ignored").read_text(), "keep")

    def test_clone_failure_preserves_source(self):
        self.dirty()
        shutil.rmtree(self.repo)
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing source was preserved", result.stderr)
        self.assertEqual((self.source / "install.sh").read_text(), "manual edit\n")
        self.assertEqual(self.backups(), [])
        self.assert_runtime_untouched()

    def test_backup_reservation_failure(self):
        self.dirty()
        self.fake("mktemp", '[[ "$*" != *backup-* ]] || exit 9\nexec /usr/bin/mktemp "$@"')
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to reserve source backup", result.stderr)
        self.assertEqual((self.source / "install.sh").read_text(), "manual edit\n")
        self.assert_runtime_untouched()

    def test_backup_rename_failure(self):
        self.dirty()
        self.fake("mv", '[[ "$*" != *backup-* ]] || exit 9\nexec /usr/bin/mv "$@"')
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to archive existing source", result.stderr)
        self.assertEqual((self.source / "install.sh").read_text(), "manual edit\n")
        self.assert_runtime_untouched()

    def test_publish_failure_and_retry(self):
        self.dirty()
        self.fake("mv", '[[ "$*" != *staging.* ]] || exit 9\nexec /usr/bin/mv "$@"')
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        backup, = self.backups()
        self.assertIn(str(backup), result.stderr)
        self.assertEqual((backup / "install.sh").read_text(), "manual edit\n")
        self.assert_runtime_untouched()
        (self.bin / "mv").unlink()
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual((backup / "install.sh").read_text(), "manual edit\n")

    def test_unique_backups_same_timestamp(self):
        self.fake("date", 'echo 20261010T133000Z')
        for _ in range(2):
            self.dirty()
            (self.runtime / ".installed-commit").write_text("old\n")
            self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual(len(self.backups()), 2)

    def test_symlinks_traversal_and_runtime_overlap(self):
        alias = self.base / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        dangling = self.base / "dangling"
        dangling.symlink_to(self.base / "absent")
        for path in (alias, dangling, f"{self.base}/x/../source", self.runtime,
                     self.runtime / "source", self.base):
            with self.subTest(path=path):
                result = self.run_launcher(PGW_SRC_DIR=str(path))
                self.assertNotEqual(result.returncode, 0)
                self.assert_runtime_untouched()
        self.assertTrue(alias.is_symlink())
        self.assertTrue(dangling.is_symlink())

    def test_writable_parent_refused(self):
        self.base.chmod(0o777)
        try:
            result = self.run_launcher()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not writable", result.stderr)
            self.assert_runtime_untouched()
        finally:
            self.base.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
