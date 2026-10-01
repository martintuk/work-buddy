"""Real local Git remotes with a fake installer and clock; no network or app restarts."""
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from xml.parsers.expat import ExpatError


ROOT = Path(__file__).resolve().parents[2]


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="work-buddy watch ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "consumer"
        self.repo.mkdir()
        self.remote = self.root / "origin.git"
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Watch Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        scripts = self.repo / "Scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "Scripts/watch-main.sh", scripts / "watch-main.sh")
        self.write_script(scripts / "run.sh", '''
revision="$(git rev-parse --short=12 HEAD)"
echo "$revision $(date +%s)" >> "$TEST_STATE/installs"
if [[ -f "$TEST_STATE/fail-next" ]]; then
    rm "$TEST_STATE/fail-next"
    echo 'simulated compiler failure' >&2
    exit 1
fi
app="$WORK_BUDDY_APP_DIR/Work Buddy.app"
mkdir -p "$app/Contents"
/usr/libexec/PlistBuddy -c 'Clear dict' -c "Add :WorkBuddyRevision string $revision" "$app/Contents/Info.plist"
''')
        (self.repo / ".gitignore").write_text("build/\n")
        self.git("add", ".")
        self.git("commit", "-m", "Initial checkout")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.revision = self.git("rev-parse", "--short=12", "HEAD")
        self.app_dir = self.root / "Applications"
        self.plist = self.app_dir / "Work Buddy.app/Contents/Info.plist"
        self.clock = self.root / "clock"
        self.clock.write_text("0")
        self.installs = self.root / "installs"
        self.installs.touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_script(self.bin / "date", '''
if [[ "$1" == +%s ]]; then cat "$TEST_STATE/clock"; else /bin/date "$@"; fi
''')
        self.write_script(self.bin / "sleep", '''
value=$(cat "$TEST_STATE/clock")
echo $((value + $1)) > "$TEST_STATE/clock.next"
mv "$TEST_STATE/clock.next" "$TEST_STATE/clock"
/bin/sleep 0.02
''')
        self.environment = dict(os.environ, WORK_BUDDY_APP_DIR=str(self.app_dir),
                                TEST_STATE=str(self.root), PATH=f"{self.bin}:/usr/bin:/bin")

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True).stdout.strip()

    def write_script(self, path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def mark_installed(self, revision):
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        self.plist.write_bytes(plistlib.dumps({"WorkBuddyRevision": revision}))

    def start_watch(self):
        log = (self.root / "watch-output").open("a")
        self.addCleanup(log.close)
        process = subprocess.Popen([str(self.repo / "Scripts/watch-main.sh"), "5"],
                                   env=self.environment, stdout=log, stderr=log,
                                   start_new_session=True)
        self.process = process
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
        self.addCleanup(stop)
        return stop

    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process.poll() is not None:
                break
            time.sleep(0.02)
        self.fail((self.root / "watch-output").read_text(errors="replace"))

    def installed_revision(self):
        try:
            return plistlib.loads(self.plist.read_bytes()).get("WorkBuddyRevision")
        except (FileNotFoundError, plistlib.InvalidFileException, ExpatError):
            return None

    def test_initial_install_without_new_commits(self):
        self.start_watch()
        self.wait_for(lambda: self.installed_revision() == self.revision)
        self.wait_for(lambda: int(self.clock.read_text()) >= 20)
        self.assertEqual(len(self.installs.read_text().splitlines()), 1)

    def test_current_install_is_not_restarted(self):
        self.mark_installed(self.revision)
        self.start_watch()
        self.wait_for(lambda: int(self.clock.read_text()) >= 20)
        self.assertEqual(self.installs.read_text(), "")

    def test_fetches_and_installs_new_remote_commit(self):
        self.mark_installed(self.revision)
        producer = self.root / "producer"
        self.git("clone", "-b", "main", str(self.remote), str(producer))
        (producer / "feature.txt").write_text("New feature")
        self.git("add", ".", cwd=producer)
        self.git("-c", "user.name=Watch Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                 "commit", "-m", "Remote update", cwd=producer)
        revision = self.git("rev-parse", "--short=12", "HEAD", cwd=producer)
        self.git("push", "origin", "main", cwd=producer)
        self.start_watch()
        self.wait_for(lambda: self.installed_revision() == revision)
        self.assertEqual(self.git("rev-parse", "--short=12", "HEAD"), revision)

    def test_failed_build_retries_same_commit_after_sixty_seconds(self):
        (self.root / "fail-next").touch()
        self.start_watch()
        self.wait_for(lambda: self.installed_revision() == self.revision)
        attempts = [line.split() for line in self.installs.read_text().splitlines()]
        self.assertEqual(len(attempts), 2)
        self.assertEqual(attempts[0][0], attempts[1][0])
        self.assertGreaterEqual(int(attempts[1][1]) - int(attempts[0][1]), 60)

    def test_restart_recovers_stale_install(self):
        self.mark_installed("older-commit")
        self.start_watch()
        self.wait_for(lambda: self.installed_revision() == self.revision)

    def test_waits_until_working_tree_is_clean(self):
        pending = self.repo / "uncommitted.txt"
        pending.write_text("Work in progress")
        self.start_watch()
        self.wait_for(lambda: int(self.clock.read_text()) >= 20)
        self.assertEqual(self.installs.read_text(), "")
        pending.unlink()
        self.wait_for(lambda: self.installed_revision() == self.revision)

    def test_does_not_install_another_branch(self):
        self.git("checkout", "-b", "feature")
        self.start_watch()
        self.wait_for(lambda: int(self.clock.read_text()) >= 20)
        self.assertEqual(self.installs.read_text(), "")


if __name__ == "__main__":
    unittest.main()
