"""Comparing two set score files: pairs by item and variant, tolerances, and a table without transcript text."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('compare_lab_scores', Path(__file__).with_name('compare-lab-scores.py'))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


def variant(name='current', deletions=5, insertions=1, substitutions=4, words=100, cleaned_deletions=None, live=0.73, pass_=0.92, cpu=12.0):
    raw = dict(referenceWords=words, substitutions=substitutions, deletions=deletions, insertions=insertions)
    cleaned = dict(raw, deletions=deletions if cleaned_deletions is None else cleaned_deletions)
    return dict(name=name, rows=10, paragraphs=4, raw=raw, cleaned=cleaned, liveSpeakerAccuracy=live, passSpeakerAccuracy=pass_,
                timings=dict(audioSeconds=600, recognitionSeconds=60, speakerPassSeconds=30, cpuSeconds=100, speakerPassCPUSeconds=20),
                cpuSecondsPerAudioMinute=cpu)


def scores(*items):
    return dict(set='synthetic', jotVersion='0.3.7', createdAt='2026-11-12T16:00:00Z',
                items=[dict(name=name, audioSeconds=600, variants=variants) for name, variants in items])


class CompareTests(unittest.TestCase):
    def test_equal_scores_pass_and_the_table_names_every_pair(self):
        base = scores(('clean', [variant(), variant('steadier')]), ('conversation', [variant()]))
        rows, failures = compare.compare(base, base)
        self.assertEqual(failures, [])
        self.assertEqual([(row['item'], row['variant']) for row in rows], [('clean', 'current'), ('clean', 'steadier'), ('conversation', 'current')])
        text = compare.table(rows)
        self.assertIn('| clean | current | 10.0% → 10.0% | 10.0% → 10.0% | 5 → 5 | 1 → 1 | 73.0% → 73.0% | 92.0% → 92.0% | 12.0 → 12.0 |', text)

    def test_a_word_error_rise_beyond_tolerance_fails_with_its_numbers(self):
        base = scores(('reverb', [variant(deletions=15)]))
        worse = scores(('reverb', [variant(deletions=17)]))        # 20% -> 22%
        _, failures = compare.compare(base, worse)
        self.assertEqual(failures, ['reverb / current: WER raw rose 20.0% → 22.0% (tolerance 1.0 points)',
                                    'reverb / current: WER cleaned rose 20.0% → 22.0% (tolerance 1.0 points)'])
        _, failures = compare.compare(base, worse, dict(compare.TOLERANCES, wer_rise=2.0))
        self.assertEqual(failures, [])
        _, failures = compare.compare(base, scores(('reverb', [variant(deletions=10)])))
        self.assertEqual(failures, [], 'an improvement never fails')

    def test_speaker_drops_cpu_rises_and_missing_pairs_fail(self):
        base = scores(('conversation', [variant()]), ('clean', [variant(live=None, pass_=None)]))
        _, failures = compare.compare(base, scores(('conversation', [variant(live=0.70)]), ('clean', [variant(live=None, pass_=None)])))
        self.assertEqual(failures, ['conversation / current: live speakers dropped 73.0% → 70.0% (tolerance 2.0 points)'])
        _, failures = compare.compare(base, scores(('conversation', [variant(cpu=16.0)]), ('clean', [variant(live=None, pass_=None)])))
        self.assertEqual(failures, ['conversation / current: CPU per audio minute rose 12.0 → 16.0 s (tolerance 30%)'])
        _, failures = compare.compare(base, scores(('conversation', [variant(pass_=None)]), ('clean', [variant(live=None, pass_=None)])))
        self.assertEqual(failures, ['conversation / current: pass speakers were scored in the baseline but not in the candidate'])
        rows, failures = compare.compare(base, scores(('conversation', [variant()])))
        self.assertEqual(failures, ['clean / current: in the baseline but not in the candidate'])
        rows, failures = compare.compare(scores(('conversation', [variant()])), base)
        self.assertEqual(failures, [])
        self.assertIn('10.0% (new)', compare.table(rows))

    def test_report_states_the_verdict(self):
        base = scores(('clean', [variant()]))
        text, failures = compare.report(base, base)
        self.assertIn('No regression beyond tolerance.', text)
        text, failures = compare.report(base, scores(('clean', [variant(insertions=4)])))
        self.assertIn('Regressions beyond tolerance:\n- clean / current: WER raw rose', text)
        self.assertEqual(len(failures), 2)


if __name__ == '__main__':
    unittest.main()
