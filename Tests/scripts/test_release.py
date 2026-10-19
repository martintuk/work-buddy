"""Check release failure boundaries without signing or contacting Apple."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "Developer ID Application: Example (TEAMID)"
HASH = "1234567890ABCDEF1234567890ABCDEF12345678"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="work-buddy release ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts/release.sh", scripts / "release.sh")
        self.bundle = self.root / "build/work-buddy.app"
        (self.bundle / "Contents/MacOS").mkdir(parents=True)
        (self.bundle / "Contents/MacOS/WorkBuddy").write_text("executable")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events"
        self.events.touch()
        self.environment = dict(os.environ, TEST_ROOT=str(self.root),
                                TEST_EVENTS=str(self.events),
                                WORK_BUDDY_SIGNING_IDENTITY=IDENTITY,
                                WORK_BUDDY_NOTARY_PROFILE="test profile",
                                PATH=f"{self.bin}:/usr/bin:/bin")
        self.destination = self.root / "build/releases/1.2.3-4"
        self.write_script(scripts / "build.sh", f'''
echo build >> "$TEST_EVENTS"
[[ "$1" == release && "$WORK_BUDDY_UNIVERSAL" == 1 ]] || exit 1
[[ "$WORK_BUDDY_VERSION" == 1.2.3 && "$WORK_BUDDY_BUILD_NUMBER" == 4 ]] || exit 1
[[ "$WORK_BUDDY_SIGNING_IDENTITY" == {HASH} ]] || exit 1
[[ "${{TEST_FAIL:-}}" != build ]] || exit 1
printf '%s/build/work-buddy.app\\n' "$TEST_ROOT"
''')
        for name, body in {
            "security": f'''printf '  1) {HASH} "{IDENTITY}"\\n'
printf '  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example (TEAMID)"\\n' ''',
            "codesign": '''echo signature >> "$TEST_EVENTS"
[[ "${TEST_FAIL:-}" != signature ]] || exit 1''',
            "lipo": '''[[ "$1" == */Contents/MacOS/WorkBuddy && "$2" == -verify_arch ]] || exit 1
[[ $# == 3 && ( "$3" == arm64 || "$3" == x86_64 ) ]] || exit 1
[[ "${TEST_FAIL:-}" != architecture ]] || exit 1''',
            "spctl": '''echo gatekeeper >> "$TEST_EVENTS"
[[ "${TEST_FAIL:-}" != gatekeeper ]] || exit 1''',
            "ditto": '''if [[ "$1" == -c ]]; then
    if [[ "$6" == */submission.zip ]]; then
        echo submission > "$6"
    else
        [[ "${TEST_FAIL:-}" != archive ]] || exit 1
        [[ -f "$5/stapled" && -f "$5/validated" ]] || exit 1
        echo stapled > "$6"
        echo archive >> "$TEST_EVENTS"
    fi
else
    /bin/cp -R "$1" "$2"
fi''',
            "xcrun": '''if [[ "$1" == --find ]]; then exit 0; fi
case "$1 $2" in
    "notarytool submit")
        echo submit >> "$TEST_EVENTS"
        [[ "$5" == "test profile" ]] || exit 1
        cat "$TEST_ROOT/response.plist"
        [[ "${TEST_FAIL:-}" != submit ]] || exit 1
        ;;
    "notarytool log")
        [[ "${TEST_FAIL:-}" != log ]] || exit 1
        echo '{}' > "$6"
        ;;
    "stapler staple")
        [[ "${TEST_FAIL:-}" != staple ]] || exit 1
        touch "$3/stapled"
        echo staple >> "$TEST_EVENTS"
        ;;
    "stapler validate")
        [[ "${TEST_FAIL:-}" != validate ]] || exit 1
        [[ -f "$3/stapled" ]] || exit 1
        touch "$3/validated"
        ;;
    *) exit 99 ;;
esac''',
        }.items():
            self.write_script(self.bin / name, body)
        self.set_response("Accepted")

    def write_script(self, path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def set_response(self, status):
        (self.root / "response.plist").write_bytes(
            plistlib.dumps({"id": "example-submission", "status": status}))

    def run_release(self, failure="", arguments=("1.2.3", "4"), **environment):
        return subprocess.run([str(self.root / "scripts/release.sh"), *arguments],
                              env=dict(self.environment, TEST_FAIL=failure, **environment),
                              capture_output=True, text=True)

    def test_packages_only_stapled_app_and_relative_checksum(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.destination / "work-buddy-1.2.3-universal.zip"
        self.assertEqual(archive.read_text(), "stapled\n")
        self.assertTrue((self.destination / "Work Buddy.app/stapled").exists())
        self.assertFalse((self.destination / "submission.zip").exists())
        checksum = subprocess.run(["shasum", "-a", "256", "-c", archive.name + ".sha256"],
                                  cwd=self.destination, capture_output=True, text=True)
        self.assertEqual(checksum.returncode, 0, checksum.stderr)
        events = self.events.read_text().splitlines()
        self.assertLess(events.index("submit"), events.index("staple"))
        self.assertLess(events.index("staple"), events.index("gatekeeper"))
        self.assertLess(events.index("gatekeeper"), events.index("archive"))

    def test_rejects_invalid_inputs_before_building(self):
        for arguments in [(), ("1.2.3",), ("../bad", "4"), ("1.2.3", "0"),
                          ("1.2.3", "4", "extra")]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_release(arguments=arguments).returncode, 64)
        for environment in [dict(WORK_BUDDY_SIGNING_IDENTITY=""),
                            dict(WORK_BUDDY_NOTARY_PROFILE=""),
                            dict(WORK_BUDDY_SIGNING_IDENTITY="-"),
                            dict(WORK_BUDDY_SIGNING_IDENTITY="Apple Development: Example (TEAMID)")]:
            with self.subTest(environment=environment):
                self.assertNotEqual(self.run_release(**environment).returncode, 0)
        self.assertEqual(self.events.read_text(), "")

    def test_accepts_distribution_certificate_hash(self):
        result = self.run_release(WORK_BUDDY_SIGNING_IDENTITY=HASH.lower())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_refuses_to_overwrite_existing_release(self):
        self.destination.mkdir(parents=True)
        sentinel = self.destination / "existing"
        sentinel.write_text("keep")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertEqual(self.events.read_text(), "")

    def test_failures_never_publish_release(self):
        for failure in ["build", "signature", "architecture", "submit", "staple",
                        "validate", "gatekeeper", "archive"]:
            with self.subTest(failure=failure):
                result = self.run_release(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())
                self.assertIn("diagnostic files retained", result.stderr)

    def test_unaccepted_or_missing_status_never_staples(self):
        for status in ["Invalid", "In Progress", ""]:
            with self.subTest(status=status):
                self.set_response(status)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())
                self.assertNotIn("staple", self.events.read_text().splitlines())

    def test_log_download_failure_does_not_discard_accepted_release(self):
        result = self.run_release("log")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Could not retrieve notarization log", result.stderr)


if __name__ == "__main__":
    unittest.main()
