import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / 'check-suggestion-results.py'
spec = importlib.util.spec_from_file_location('check_suggestion_results', SCRIPT)
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)
CORPUS_BYTES = results.DEFAULT_CORPUS.read_bytes()
CORPUS = json.loads(CORPUS_BYTES)


def fake_run(mode='normal', iterations=1):
    """A structurally complete run labeled test-fake. The text is test data, not model output."""
    run = {
        'format': results.RUN_FORMAT, 'version': 1, 'runId': 'test-run', 'mode': mode, 'generator': 'test-fake',
        'iterations': iterations, 'startedAt': '2026-09-26T00:00:00Z', 'finishedAt': '2026-09-26T00:01:00Z',
        'completed': True, 'stopReason': None, 'recordCount': 0, 'sourceRevision': None,
        'corpus': {'path': 'docs/evaluation/contextual-suggestions/scenarios.json',
                   'sha256': hashlib.sha256(CORPUS_BYTES).hexdigest(), 'format': CORPUS['format'],
                   'version': CORPUS['version'], 'scenarioCount': len(CORPUS['scenarios'])},
        'runtime': {'operatingSystem': 'test', 'hardwareModel': None, 'modelAvailability': 'test-fake',
                    'model': 'SystemLanguageModel.default', 'modelRevision': None, 'appleFMRevision': 'test'},
        'selection': {'maximumSources': 6, 'maximumSourceBytes': 4096},
        'generation': {'sampling': 'greedy', 'maximumResponseTokens': 128, 'deadlineMs': 2000,
                       'cancellationGraceMs': 2000, 'outstandingRequests': 1, 'freshSessionPerRequest': True},
        'prompt': {'templateID': 'jot-suggestion-v1', 'abstainMarker': 'NO_SUGGESTION', 'instructionsSHA256': {}},
        'notice': 'Test data.',
    }
    records, cold = [], True
    for iteration in range(1, iterations + 1):
        for scenario in CORPUS['scenarios']:
            expected = scenario['expected']
            revisions = {source['id']: source['revision'] for source in scenario['sources']}
            included = expected['includedSources']
            if mode == 'normal':
                excluded = [dict(item) for item in expected['excludedSources']]
            else:
                excluded = [{'id': source_id, 'reason': 'not-in-oracle-context'}
                            for source_id in revisions if source_id not in included]
            record = {
                'format': results.RECORD_FORMAT, 'version': 1, 'runId': 'test-run', 'iteration': iteration,
                'mode': mode, 'scenarioId': scenario['id'], 'generator': 'test-fake', 'run': None,
                'selectedSources': [{'id': source_id, 'revision': revisions[source_id]} for source_id in included],
                'excludedSources': excluded, 'outcome': 'abstain', 'detail': 'no-selected-source', 'rawOutput': None,
                'outputText': None, 'change': None, 'timeToPreviewMs': None, 'generationMs': None, 'durationMs': 1,
                'promptSHA256': None, 'selectionComparison': None, 'outcomeComparison': None,
                'scores': {criterion: None for criterion in scenario['scoring']['criteria']}, 'scorer': None,
                'notes': None,
            }
            if included or scenario['target']['mode'] == 'draft':
                record.update(run='cold' if cold else 'warm', promptSHA256='0' * 64, generationMs=3)
                cold = False
                if expected['outcome'] == 'abstain':
                    record.update(rawOutput='NO_SUGGESTION', detail='model-abstained')
                else:
                    record.update(outcome='suggest', detail=None, rawOutput='TEST DATA', outputText='TEST DATA',
                                  timeToPreviewMs=4)
            if 'change' in scenario:
                withdrawn = True if record['outcome'] == 'suggest' else None
                record['change'] = {'kind': scenario['change']['kind'], 'generatedPreviewWithdrawn': withdrawn,
                                    'authoredPreviewWithdrawn': True}
                if withdrawn:
                    record['outcome'] = 'invalidate'
            if mode == 'normal':
                record['selectionComparison'] = {'matchesExpected': True, 'missingSources': [],
                                                 'unexpectedSources': [], 'reasonMismatches': []}
            record['outcomeComparison'] = {'expected': expected['outcome'],
                                           'matches': expected['outcome'] == record['outcome']}
            records.append(record)
    run['recordCount'] = len(records)
    return run, records


class SuggestionResultTests(unittest.TestCase):
    def setUp(self):
        self.run_data, self.records = fake_run()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)

    def write(self, run=None, records=None, lines=None):
        (self.path / 'run.json').write_text(json.dumps(run or self.run_data), encoding='utf-8')
        if lines is None:
            lines = [json.dumps(record) for record in (records if records is not None else self.records)]
        (self.path / 'results.jsonl').write_text(''.join(line + '\n' for line in lines), encoding='utf-8')

    def errors(self, run=None, records=None, lines=None):
        self.write(run, records, lines)
        return results.validate(self.path, results.DEFAULT_CORPUS)[0]

    def assertRejected(self, fragment, run=None, records=None, lines=None):
        errors = self.errors(run, records, lines)
        self.assertTrue(any(fragment in error for error in errors), f'{fragment!r} not in {errors}')

    def record(self, scenario_id, iteration=1):
        return next(record for record in self.records
                    if record['scenarioId'] == scenario_id and record['iteration'] == iteration)

    def run_command(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.path)], capture_output=True, text=True)

    def test_fake_runs_in_both_modes_are_valid_and_labeled(self):
        self.assertEqual(self.errors(), [])
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('labeled test-fake', result.stdout)
        self.assertIn('assigns no quality scores', result.stdout)
        run, records = fake_run(mode='oracle-context', iterations=2)
        self.assertEqual(self.errors(run, records), [])

    def test_rejects_missing_or_unknown_keys_and_bad_json(self):
        del self.record('shell-blank-matching-project')['detail']
        self.assertRejected("missing 'detail'")
        self.setUp()
        self.record('shell-blank-matching-project')['score'] = 'pass'
        self.assertRejected("unknown key 'score'")
        self.assertRejected('invalid JSON', lines=['{"format": 1, "format": 2}'])

    def test_rejects_outputs_inconsistent_with_the_outcome(self):
        self.record('shell-blank-matching-project')['outputText'] = None
        self.assertRejected('suggest needs rawOutput, outputText and timeToPreviewMs')
        self.setUp()
        self.record('agent-unknown-preference')['outputText'] = 'Tabs.'
        self.assertRejected('abstain has no outputText')
        self.setUp()
        self.record('shell-blank-unrelated-project').update(outcome='suggest', rawOutput='x', outputText='x',
                                                              timeToPreviewMs=1)
        self.assertRejected('abstain before inference')
        self.setUp()
        self.record('shell-blank-matching-project').update(outcome='unavailable', detail='model_not_ready',
                                                            rawOutput=None, outputText=None, timeToPreviewMs=None)
        self.assertRejected('neither cold nor warm')

    def test_drafts_are_generated_without_a_source_and_other_modes_are_not(self):
        draft = self.record('draft-seed-only-casual-reply')
        self.assertEqual((draft['selectedSources'], draft['outcome']), ([], 'suggest'))
        self.assertEqual(self.errors(), [])
        draft.update(outcome='abstain', detail='no-selected-source', run=None, promptSHA256=None, generationMs=None,
                     rawOutput=None, outputText=None, timeToPreviewMs=None,
                     outcomeComparison={'expected': 'suggest', 'matches': False})
        self.assertRejected('a draft is generated from its notes, so every draft record has a request')
        self.setUp()
        self.record('draft-notes-without-intent').update(run=None, promptSHA256=None, generationMs=None,
                                                          rawOutput=None, detail=None)
        self.assertRejected('every draft record has a request')
        self.setUp()
        self.record('shell-blank-unrelated-project').update(run='warm', promptSHA256='0' * 64, generationMs=3,
                                                              rawOutput='NO_SUGGESTION', detail='model-abstained')
        self.assertRejected('abstain before inference')
        self.write()
        self.assertEqual(results.validate(self.path)[0], [], 'Without the corpus, a request with no source may be a draft')

    def test_rejects_invalidation_without_a_withdrawn_preview(self):
        self.record('agent-same-length-edit-after-preview')['change']['generatedPreviewWithdrawn'] = False
        self.assertRejected('invalidate means a generated preview was withdrawn')
        self.setUp()
        self.record('agent-same-length-edit-after-preview')['change'] = None
        self.assertRejected('invalidate requires a change')

    def test_scores_need_a_reviewer_and_known_values(self):
        record = self.record('shell-blank-matching-project')
        record['scores']['useful'] = 'pass'
        self.assertRejected('a recorded score needs a named reviewer')
        record['scorer'] = 'Reviewer'
        self.assertEqual(self.errors(), [])
        record['scores']['useful'] = 'good'
        self.assertRejected('must be null or one of')
        self.setUp()
        self.record('shell-blank-matching-project')['scores'] = {'outcome': None}
        self.assertRejected("keys must be the scenario's scoring criteria")

    def test_only_the_first_request_is_cold(self):
        self.record('agent-explain-before-fix')['run'] = 'cold'
        self.assertRejected('exactly the first request of the run is cold')

    def test_rejects_records_that_do_not_match_the_corpus(self):
        self.record('shell-blank-matching-project')['scenarioId'] = 'invented-scenario'
        self.assertRejected('is not in the corpus')
        self.setUp()
        self.record('shell-blank-matching-project')['excludedSources'] = []
        self.record('shell-blank-matching-project')['selectedSources'].pop()
        self.assertRejected('must list every scenario source exactly once')
        self.setUp()
        self.run_data['corpus']['sha256'] = 'f' * 64
        self.assertRejected('does not match')

    def test_counts_and_incomplete_runs(self):
        self.assertRejected('recordCount', records=self.records[:-1])
        self.setUp()
        self.run_data.update(completed=False, stopReason='A timed-out model request had not returned.',
                             recordCount=3)
        self.write(records=self.records[:3])
        result = self.run_command()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('Run incomplete', result.stderr)
        self.setUp()
        self.run_data['completed'] = True
        self.run_data['stopReason'] = 'stopped'
        self.assertRejected('a completed run has a finish time and no stop reason')

    def test_model_revision_stays_unknown(self):
        run = copy.deepcopy(self.run_data)
        run['runtime']['modelRevision'] = 'invented'
        self.assertRejected('Apple does not expose a model revision', run=run)


if __name__ == '__main__':
    unittest.main()
