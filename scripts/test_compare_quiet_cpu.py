import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('compare_quiet_cpu', Path(__file__).with_name('compare-quiet-cpu.py'))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class CompareQuietCPUTests(unittest.TestCase):
    def test_summary_keeps_cpu_lines_only(self):
        text = '\n'.join([
            'QUIET CPU: quiet room: 60.0 audio s, CPU s per audio minute 0.40, wall 2.0 s, 75 jobs, 75 without speech',
            'QUIET CPU SPEECH JOBS: 12, recognition median 0.190 s, max 0.400 s',
            'QUIET CPU ROW: [0.00-2.10] S1: We should move the review',
            'QUIET CPU WORD: [0.10] We 0.9',
        ])
        self.assertEqual(compare.summary(text), text.splitlines()[:2])

    def test_label_is_a_file_name(self):
        self.assertEqual(compare.label('origin/claude/thread-1'), 'origin-claude-thread-1')


if __name__ == '__main__':
    unittest.main()
