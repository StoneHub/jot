"""The accuracy gate's orchestration with every build, git and lab run mocked: baseline cache, candidate run, verdict."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('lab_accuracy_check', Path(__file__).with_name('lab-accuracy-check.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

BASE = 'b' * 40
HEAD = 'c' * 40


def scores(deletions):
    raw = dict(referenceWords=100, substitutions=2, deletions=deletions, insertions=1)
    return dict(set='synthetic', jotVersion='0.3.7', createdAt='t', items=[dict(name='clean', audioSeconds=60, variants=[
        dict(name='current', rows=3, paragraphs=1, raw=raw, cleaned=raw, liveSpeakerAccuracy=None, passSpeakerAccuracy=None,
             timings=dict(audioSeconds=60, recognitionSeconds=5, speakerPassSeconds=2, cpuSeconds=4, speakerPassCPUSeconds=1),
             cpuSecondsPerAudioMinute=5.0)])])


class GateTests(unittest.TestCase):
    def setUp(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / '.git').mkdir()
        os.chdir(self.root)
        self.set = self.root.parent / f'{self.root.name}-set'
        self.set.mkdir()
        self.addCleanup(lambda: __import__('shutil').rmtree(self.set, ignore_errors=True))
        (self.set / 'a.wav').write_bytes(b'RIFF')
        (self.set / 'a.vtt').write_text('WEBVTT\n')
        (self.set / 'set.json').write_text(json.dumps(dict(name='synthetic', items=[dict(name='clean', audio='a.wav', captions='a.vtt')])))
        self.baseline_deletions = 5
        self.candidate_deletions = 5
        self.builds = []
        self.runs = []

    def fake_output(self, command, **kwargs):
        cwd = Path(kwargs.get('cwd', '.')).resolve()
        if command[:3] == ['git', 'rev-parse', '--path-format=absolute']:
            return str(self.root / '.git') + '\n'
        if command[:3] == ['git', 'rev-parse', '--show-toplevel']:
            return str(cwd) + '\n'
        if command[:3] == ['git', 'rev-parse', 'HEAD']:
            return HEAD + '\n'
        if command[:3] == ['git', 'rev-parse', '--verify']:
            return BASE + '\n'
        if command[:2] == ['git', 'worktree']:
            if command[2] == 'add':
                Path(command[5]).mkdir(parents=True)
            return ''
        if command[:2] == ['git', 'checkout']:
            return ''
        raise AssertionError(command)

    def fake_run(self, command, **kwargs):
        if command[0] == 'xcodebuild':
            self.builds.append(Path(kwargs['cwd']).resolve())
            return subprocess.CompletedProcess(command, 0)
        if command[1] == '--set':
            binary = Path(command[0])
            self.runs.append(binary)
            out = Path(command[command.index('--out') + 1])
            out.mkdir(parents=True)
            baseline = 'lab-baseline' in binary.parts
            (out / 'set-scores.json').write_text(json.dumps(scores(self.baseline_deletions if baseline else self.candidate_deletions)))
            return subprocess.CompletedProcess(command, 0)
        raise AssertionError(command)

    def run_gate(self, *args):
        with patch('subprocess.check_output', side_effect=self.fake_output), patch('subprocess.run', side_effect=self.fake_run), \
                patch('platform.system', return_value='Darwin'), patch('shutil.which', return_value=None), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            code = gate.main(['--set', str(self.set), '--baseline-ref', 'origin/main', *args])
        return code, out.getvalue()

    def test_baseline_is_built_once_and_cached_then_the_candidate_is_compared(self):
        code, output = self.run_gate()
        self.assertEqual(code, 0)
        self.assertEqual(self.builds, [self.root / 'work/lab-baseline', self.root])
        self.assertEqual(len(self.runs), 2)
        cache = list((self.root / 'work/lab-baselines').glob(f'{BASE}-*.json'))
        self.assertEqual(len(cache), 1)
        self.assertIn('## Lab accuracy: PASS', (self.root / 'work/lab-accuracy' / HEAD[:7] / 'accuracy-report.md').read_text())
        self.builds.clear(); self.runs.clear()
        code, _ = self.run_gate()
        self.assertEqual(code, 0)
        self.assertEqual(self.builds, [self.root], 'the cached baseline is reused')
        self.assertEqual(len(self.runs), 1)

    def test_a_regression_fails_with_the_table(self):
        self.candidate_deletions = 9
        code, output = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn('## Lab accuracy: FAIL', output)
        self.assertIn('clean / current: WER raw rose 8.0% → 12.0%', output)

    def test_a_changed_set_means_a_new_baseline_run(self):
        self.run_gate()
        (self.set / 'a.wav').write_bytes(b'RIFF longer')
        self.builds.clear()
        self.run_gate()
        self.assertEqual(self.builds, [self.root / 'work/lab-baseline', self.root])
        self.assertEqual(len(list((self.root / 'work/lab-baselines').glob(f'{BASE}-*.json'))), 2)

    def test_candidate_binary_skips_the_candidate_build(self):
        code, _ = self.run_gate('--candidate-binary', str(self.root / 'prebuilt/jot-lab'))
        self.assertEqual(code, 0)
        self.assertEqual(self.builds, [self.root / 'work/lab-baseline'])

    def test_needs_a_set_and_a_mac(self):
        with patch('platform.system', return_value='Linux'), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            gate.main(['--baseline-ref', 'origin/main'])
        with patch('platform.system', return_value='Darwin'), patch.dict(os.environ, {'JOT_LAB_SET': ''}), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            gate.main(['--baseline-ref', 'origin/main'])


if __name__ == '__main__':
    unittest.main()
