"""Exercise installation failures without touching the real app or processes.

Run with: python3 -m unittest discover -s Tests/scripts
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="work-buddy scripts ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts/run.sh", scripts / "run.sh")
        self.bundle = self.root / "build/work-buddy.app"
        self.bundle.mkdir(parents=True)
        (self.bundle / "version").write_text("new")
        self.app_dir = self.root / "My Applications"
        self.app = self.app_dir / "Work Buddy.app"
        self.app.mkdir(parents=True)
        (self.app / "version").write_text("old")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events"
        self.events.touch()
        self.environment = dict(os.environ, WORK_BUDDY_APP_DIR=str(self.app_dir),
                                TEST_ROOT=str(self.root), TEST_EVENTS=str(self.events),
                                PATH=f"{self.bin}:/usr/bin:/bin")
        self.write_script(scripts / "build.sh", '''
[[ "${TEST_FAIL:-}" != build ]] || exit 1
printf '%s/build/work-buddy.app\\n' "$TEST_ROOT"
''')
        for name, body in {
            "codesign": '[[ "${TEST_FAIL:-}" != verify ]]',
            "pkill": 'echo stop >> "$TEST_EVENTS"',
            "pgrep": '[[ "${TEST_FAIL:-}" == stop ]]',
            "sleep": ':',
            "open": '''echo "open:$2" >> "$TEST_EVENTS"
[[ "${TEST_FAIL:-}" != open || "$(cat "$2/version")" == old ]]''',
            "ditto": '''[[ "${TEST_FAIL:-}" != copy ]] || exit 1
/bin/cp -R "$1" "$2"''',
            "mv": '''if [[ "${TEST_FAIL:-}" == move && "$1" == */.work-buddy-install.*/"Work Buddy.app" ]]; then
    exit 1
fi
/bin/mv "$@"''',
        }.items():
            self.write_script(self.bin / name, body)

    def write_script(self, path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_install(self, failure="", arguments=()):
        return subprocess.run([str(self.root / "scripts/run.sh"), *arguments],
                              env=dict(self.environment, TEST_FAIL=failure),
                              capture_output=True, text=True)

    def assert_clean(self):
        self.assertEqual(list(self.app_dir.glob(".work-buddy-install.*")), [])

    def test_installs_and_opens_stable_path(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "version").read_text(), "new")
        self.assertEqual(self.events.read_text().splitlines(), ["stop", f"open:{self.app}"])
        self.assert_clean()

    def test_first_install(self):
        shutil.rmtree(self.app_dir)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "version").read_text(), "new")
        self.assert_clean()

    def test_preparation_failures_leave_running_app_untouched(self):
        for failure in ["build", "copy", "verify"]:
            with self.subTest(failure=failure):
                self.assertNotEqual(self.run_install(failure).returncode, 0)
                self.assertEqual((self.app / "version").read_text(), "old")
                self.assertEqual(self.events.read_text(), "")
                self.assert_clean()

    def test_rejects_unknown_configuration_before_building(self):
        result = self.run_install(arguments=["bogus"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("Usage:", result.stderr)
        self.assertEqual((self.app / "version").read_text(), "old")
        self.assertEqual(self.events.read_text(), "")

    def test_cannot_replace_app_that_did_not_exit(self):
        self.assertNotEqual(self.run_install("stop").returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "old")
        self.assertEqual(self.events.read_text(), "stop\n")
        self.assert_clean()

    def test_restores_and_reopens_previous_version_after_publish_failure(self):
        for failure in ["move", "open"]:
            with self.subTest(failure=failure):
                self.assertNotEqual(self.run_install(failure).returncode, 0)
                self.assertEqual((self.app / "version").read_text(), "old")
                self.assertEqual(self.events.read_text().splitlines()[-1], f"open:{self.app}")
                self.assert_clean()


if __name__ == "__main__":
    unittest.main()
