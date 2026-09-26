import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / 'check-suggestion-fixtures.py'
spec = importlib.util.spec_from_file_location('check_suggestion_fixtures', SCRIPT)
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
CORPUS = fixtures.load(fixtures.DEFAULT_CORPUS)


class SuggestionFixtureTests(unittest.TestCase):
    def setUp(self):
        self.corpus = copy.deepcopy(CORPUS)

    def scenario(self, scenario_id):
        return next(scenario for scenario in self.corpus['scenarios'] if scenario['id'] == scenario_id)

    def assertRejected(self, fragment):
        errors = fixtures.validate(self.corpus)
        self.assertTrue(any(fragment in error for error in errors), f'{fragment!r} not in {errors}')

    def run_command(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)

    def run_command_on(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'scenarios.json'
            path.write_text(text, encoding='utf-8')
            return self.run_command(str(path))

    def test_committed_corpus_is_valid(self):
        self.assertEqual(fixtures.validate(self.corpus), [])
        drafts = [scenario for scenario in self.corpus['scenarios'] if scenario['target']['mode'] == 'draft']
        self.assertTrue(10 <= len(self.corpus['scenarios']) - len(drafts) <= 12)
        self.assertTrue(5 <= len(drafts) <= 8, 'a focused set of draft cases')

    def test_command_accepts_committed_corpus(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('does not measure suggestion quality', result.stdout)

    def test_command_rejects_invalid_corpus(self):
        self.corpus['scenarios'].append(copy.deepcopy(self.corpus['scenarios'][0]))
        result = self.run_command_on(json.dumps(self.corpus))
        self.assertEqual(result.returncode, 1)
        self.assertIn('duplicate scenario id', result.stderr)

    def test_command_rejects_malformed_json_and_duplicate_keys(self):
        self.assertEqual(self.run_command_on('{"format": ').returncode, 1)
        result = self.run_command_on('{"version": 1, "version": 2}')
        self.assertEqual(result.returncode, 1)
        self.assertIn('duplicate JSON key', result.stderr)

    def test_unsupported_version_and_non_synthetic_corpus(self):
        self.corpus['version'] = 2
        self.corpus['synthetic'] = False
        self.assertRejected('unsupported version 2')
        self.assertRejected('synthetic scenarios only')

    def test_duplicate_source_ids(self):
        sources = self.scenario('shell-blank-matching-project')['sources']
        sources[1]['id'] = 's1'
        self.assertRejected("duplicate source id 's1'")

    def test_dangling_references(self):
        scenario = self.scenario('shell-stale-summary-deleted-transcript')
        scenario['expected']['includedSources'].append('s9')
        scenario['sources'][1]['derivedFrom'][0]['id'] = 's8'
        scenario['expected']['excludedSources'][0]['id'] = 's7'
        self.assertRejected("includedSources: references unknown source 's9'")
        self.assertRejected("derivedFrom[0]: references unknown source 's8'")
        self.assertRejected("excludedSources[0]: references unknown source 's7'")

    def test_every_source_needs_an_expected_selection(self):
        self.scenario('shell-blank-matching-project')['expected']['includedSources'].remove('s2')
        self.assertRejected("source 's2' has no expected selection")

    def test_stale_deleted_and_cross_project_sources_cannot_be_selected(self):
        expected = self.scenario('shell-stale-summary-deleted-transcript')['expected']
        expected['excludedSources'] = [item for item in expected['excludedSources'] if item['id'] != 's3']
        expected['includedSources'].append('s3')
        self.assertRejected("'s3' is included but its status is 'deleted'")
        expected = self.scenario('shell-blank-unrelated-project')['expected']
        expected['excludedSources'] = [{'id': 's2', 'reason': 'unrelated-scope'}]
        expected['includedSources'] = ['s1']
        self.assertRejected("'s1' belongs to project 'harbor-app', not the target project")

    def test_summary_of_older_revision_cannot_be_current(self):
        scenario = self.scenario('shell-stale-summary-deleted-transcript')
        scenario['sources'][1]['status'] = 'current'
        self.assertRejected('derived from an older revision or deleted source')

    def test_generated_suggestions_and_duplicates_are_not_user_intent(self):
        expected = self.scenario('agent-duplicate-prompt-dismissed-suggestion')['expected']
        expected['excludedSources'] = []
        expected['includedSources'] = ['s1', 's2', 's3', 's4']
        self.assertRejected('shown suggestions must be excluded')
        self.assertRejected("'s1' duplicates 's2'")

    def test_authored_text_is_labelled(self):
        self.scenario('agent-explicit-fix-intent')['expected']['idealText']['origin'] = 'model'
        self.assertRejected("origin must be 'authored'")
        self.scenario('agent-speakers-disagree')['expected']['idealText'] = {'origin': 'authored', 'text': 'Ship it.'}
        self.assertRejected('only a suggest outcome can have ideal text')

    def test_invalidation_requires_a_real_change(self):
        scenario = self.scenario('agent-same-length-edit-after-preview')
        scenario['change']['before'] = scenario['target']['before']
        self.assertRejected('an input edit must change before or after')
        del scenario['change']
        self.assertRejected('invalidate requires pendingSuggestion and change')

    def test_required_coverage_and_negative_outcomes(self):
        self.corpus['scenarios'] = [scenario for scenario in self.corpus['scenarios']
                                    if 'hostile-instruction' not in scenario['covers']
                                    and scenario['expected']['outcome'] != 'invalidate']
        self.assertRejected("missing required coverage: ['changed-input-revision', 'hostile-instruction']")
        self.assertRejected("needs at least one 'invalidate' scenario")

    def test_draft_needs_notes_and_only_draft_has_them(self):
        target = self.scenario('draft-seed-only-casual-reply')['target']
        del target['seed']
        self.assertRejected('draft mode needs the non-empty notes it rewrites')
        for blank in ('', '  \n', None, 7, [], {}):
            target['seed'] = blank
            with self.subTest(seed=blank):
                self.assertRejected('draft mode needs the non-empty notes it rewrites')
        self.setUp()
        self.scenario('agent-explain-before-fix')['target']['seed'] = 'explain first'
        self.assertRejected('agent-explain-before-fix).target.seed: only draft mode has a seed')

    def test_only_a_draft_may_rest_on_its_notes_alone(self):
        self.assertEqual(self.scenario('draft-seed-only-casual-reply')['expected']['includedSources'], [])
        self.assertEqual(fixtures.validate(self.corpus), [], 'A seed-only draft suggestion is grounded in the notes')
        target = self.scenario('draft-seed-only-casual-reply')['target']
        target['mode'] = 'reply'
        del target['seed']
        self.assertRejected('draft-seed-only-casual-reply).expected.includedSources: '
                            'a suggestion must be grounded in at least one included source')

    def test_draft_scenarios_keep_the_other_selection_rules(self):
        expected = self.scenario('draft-notes-ignore-unrelated-ambient')['expected']
        expected['excludedSources'] = []
        expected['includedSources'] = ['s1']
        self.assertRejected("'s1' belongs to project 'lumen-api', not the target project")
        self.setUp()
        self.scenario('draft-notes-without-intent')['expected']['idealText'] = {'origin': 'authored', 'text': 'Hmm.'}
        self.assertRejected('only a suggest outcome can have ideal text')

    def test_unknown_keys_and_values(self):
        self.scenario('agent-unknown-preference')['expected']['idealtext'] = 'typo'
        self.scenario('agent-unknown-preference')['covers'].append('stale-sources')
        self.assertRejected("unknown key 'idealtext'")
        self.assertRejected("unknown coverage tag 'stale-sources'")

    def test_wrong_types_report_errors_without_crashing(self):
        paths = [
            ('scenarios',), ('rubric',), ('scenarios', 0), ('scenarios', 0, 'target'), ('scenarios', 0, 'sources'),
            ('scenarios', 0, 'sources', 0), ('scenarios', 0, 'sources', 0, 'scope'), ('scenarios', 0, 'expected'),
            ('scenarios', 0, 'expected', 'excludedSources'), ('scenarios', 0, 'scoring'),
            ('scenarios', 7, 'sources', 1, 'derivedFrom'), ('scenarios', 10, 'change'), ('scenarios', 10, 'pendingSuggestion'),
        ]
        for path in paths:
            parent = CORPUS
            for key in path[:-1]:
                parent = parent[key]
            wrong_container = {} if isinstance(parent[path[-1]], list) else []
            for bad in (None, 7, 'text', wrong_container):
                corpus = copy.deepcopy(CORPUS)
                parent = corpus
                for key in path[:-1]:
                    parent = parent[key]
                parent[path[-1]] = bad
                with self.subTest(path=path, bad=bad):
                    self.assertTrue(fixtures.validate(corpus))


if __name__ == '__main__':
    unittest.main()
