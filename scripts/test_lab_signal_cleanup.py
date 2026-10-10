"""Compile the real lab cleanup handler and signal only synthetic child processes."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'Sources/JotLab/main.swift'


def cleanup_function(source):
    """Extract the complete current function, including its balanced Swift braces."""
    start = source.index('func removeOnInterrupt(')
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError('Unbalanced removeOnInterrupt function')


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                     'Native signal cleanup proof requires macOS and swiftc')
class LabSignalCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='jot-lab-signal-test-')
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        source = cls.root / 'main.swift'
        source.write_text('import Foundation\n' + cleanup_function(SOURCE.read_text()) + """
let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let ready = URL(fileURLWithPath: CommandLine.arguments[2])
let sources = removeOnInterrupt(scratch)
try Data("ready".utf8).write(to: ready)
withExtendedLifetime(sources) { dispatchMain() }
""")
        cls.executable = cls.root / 'signal-cleanup'
        result = subprocess.run(['swiftc', '-swift-version', '6', '-module-cache-path', str(cls.root / 'module-cache'),
                                 str(source), '-o', str(cls.executable)],
                                capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def check_signal(self, number):
        with tempfile.TemporaryDirectory(prefix='case-', dir=self.root) as case:
            root = Path(case)
            scratch = root / 'scratch'
            scratch.mkdir()
            (scratch / 'synthetic-marker.txt').write_text('synthetic marker only')
            ready = root / 'ready'
            child = subprocess.Popen([str(self.executable), str(scratch), str(ready)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline and child.poll() is None:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), 'Child did not register its signal handlers')
                os.kill(child.pid, number)
                status = child.wait(timeout=5)
                with self.subTest(behavior='scratch removed'):
                    self.assertFalse(scratch.exists(), f'{number.name} left scratch behind')
                with self.subTest(behavior='cleanup exit status'):
                    self.assertEqual(status, 128 + number)
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)

    def test_interrupt_removes_scratch(self):
        self.check_signal(signal.SIGINT)

    def test_termination_removes_scratch(self):
        self.check_signal(signal.SIGTERM)

    def test_hangup_removes_scratch(self):
        self.check_signal(signal.SIGHUP)

    def test_broken_pipe_removes_scratch(self):
        self.check_signal(signal.SIGPIPE)


if __name__ == '__main__':
    unittest.main()
