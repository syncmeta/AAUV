#!/usr/bin/env python3
"""Exercise build transaction exclusivity, failure recovery and stage cleanup."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
LOCKER = ROOT / 'Scripts/with-build-lock.py'


class BuildStorageTests(unittest.TestCase):
    def command(self, lock, code):
        return [sys.executable, str(LOCKER), str(lock), '--', sys.executable, '-c', code]

    def test_competing_writer_rejected_and_failure_releases_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            lock = Path(temp) / 'build.lock'
            ready = Path(temp) / 'ready'
            release = Path(temp) / 'release'
            first = subprocess.Popen(self.command(lock, f"from pathlib import Path; import time; Path({str(ready)!r}).touch(); \nwhile not Path({str(release)!r}).exists(): time.sleep(.02)"))
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                competing = subprocess.run(self.command(lock, 'raise SystemExit(0)'), capture_output=True)
                self.assertEqual(competing.returncode, 75)
                self.assertIn(b'Build already running', competing.stderr)
            finally:
                release.touch()
                first.wait(timeout=5)
            failed = subprocess.run(self.command(lock, 'raise SystemExit(7)'))
            self.assertEqual(failed.returncode, 7)
            self.assertEqual(subprocess.run(self.command(lock, 'pass')).returncode, 0)

    def test_writer_retains_lock_after_coordinator_is_killed(self):
        with tempfile.TemporaryDirectory() as temp:
            lock = Path(temp) / 'build.lock'
            ready, release = Path(temp) / 'ready', Path(temp) / 'release'
            code = (f"from pathlib import Path; import os, time; "
                    f"Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                    f"while not Path({str(release)!r}).exists(): time.sleep(.02)\n")
            coordinator = subprocess.Popen(self.command(lock, code), start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                writer_pid = int(ready.read_text())
                coordinator.kill()
                coordinator.wait(timeout=5)
                os.kill(writer_pid, 0)  # The actual writer is still alive.
                result = subprocess.run(self.command(lock, 'pass'), capture_output=True)
                self.assertEqual(result.returncode, 75, result.stderr)
                release.touch()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    result = subprocess.run(self.command(lock, 'pass'), capture_output=True)
                    if result.returncode != 75:
                        break
                    time.sleep(.02)
                self.assertEqual(result.returncode, 0, result.stderr)
            finally:
                release.touch()
                # The writer was deliberately orphaned. Tear down our entire
                # private session on assertion failures rather than leaving it
                # running or relying on a global process-name search.
                try:
                    os.killpg(coordinator.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                coordinator.wait(timeout=5)

    def test_build_entry_and_package_entry_share_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ['Scripts', 'build', 'bin']:
                (root / name).mkdir()
            for name in ['package-macos.sh', 'package-macos-worker.sh', 'build-macos.sh',
                         'build-macos-worker.sh', 'with-build-lock.py']:
                (root / 'Scripts' / name).write_bytes((ROOT / 'Scripts' / name).read_bytes())
            ready, release = root / 'ready', root / 'release'
            fake = root / 'bin/xcodebuild'
            fake.write_text('#!/bin/sh\ntouch "$READY"\nwhile [ ! -e "$RELEASE" ]; do sleep 0.02; done\nexit 9\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'],
                       READY=str(ready), RELEASE=str(release))
            first = subprocess.Popen(['sh', str(root / 'Scripts/build-macos.sh')], env=env)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                second = subprocess.run(['sh', str(root / 'Scripts/package-macos.sh'),
                                         str(root / 'build/output.zip')], env=env, capture_output=True)
                self.assertEqual(second.returncode, 75, second.stderr)
            finally:
                release.touch()
                self.assertEqual(first.wait(timeout=5), 9)

    def test_failed_package_build_removes_stage_and_preserves_output(self):
        # A tiny isolated project fixture runs the real packaging shell. A fake
        # xcodebuild fails before signing, so no Apple credentials are used.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Scripts').mkdir(); (root / 'build').mkdir(); (root / 'bin').mkdir()
            for name in ['package-macos.sh', 'package-macos-worker.sh', 'with-build-lock.py', 'build-macos-worker.sh']:
                (root / 'Scripts' / name).write_bytes((ROOT / 'Scripts' / name).read_bytes())
            fake = root / 'bin/xcodebuild'; fake.write_text('#!/bin/sh\nexit 9\n'); fake.chmod(0o755)
            output = root / 'build/result.zip'
            env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'])
            for key in ['AAUV_MAC_PROVISIONING_PROFILE', 'AAUV_MAC_DEVICE_ID']:
                env.pop(key, None)
            result = subprocess.run(['sh', str(root / 'Scripts/package-macos.sh'), str(output)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 9, result.stderr)
            self.assertFalse(output.exists())
            self.assertEqual(list((root / 'build').glob('mac-package.*')), [])
            output.write_text('existing output')
            result = subprocess.run(['sh', str(root / 'Scripts/package-macos.sh'), str(output)], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), 'existing output')


if __name__ == '__main__':
    unittest.main()
