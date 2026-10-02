import importlib.util
from contextlib import ExitStack, redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parent / 'local-pr-check.py'
spec = importlib.util.spec_from_file_location('local_pr_check', SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
               GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid', GIT_CONFIG_NOSYSTEM='1')


def names(gates):
    return [gate.name for gate in gates]


class PlanTests(unittest.TestCase):
    head_files = {'scripts/test_signing.py', 'scripts/check-no-feedback.py'}

    def plan(self, files, **options):
        return check.plan(files, self.head_files, 'base', 'head', **options)

    def test_documentation_needs_only_portable_checks(self):
        gates = self.plan(['docs/PLAN.md', 'scripts/test_signing.py'])
        self.assertEqual(names(gates), ['portable'])
        commands = [' '.join(step[1:]) for step in gates[0].steps]
        self.assertIn('diff --check base head', commands)
        self.assertIn('-m unittest discover -s scripts -p test_*.py', commands)
        self.assertIn('scripts/check-no-feedback.py', commands)
        self.assertNotIn('scripts/check-suggestion-fixtures.py', commands)

    def test_optional_checks_follow_the_checked_out_tree(self):
        self.head_files = {'scripts/check-suggestion-fixtures.py'}
        commands = [' '.join(step[1:]) for step in self.plan(['README.md'])[0].steps]
        self.assertEqual(commands, ['diff --check base head', 'scripts/check-suggestion-fixtures.py'])

    def test_core_change_needs_every_mac_gate(self):
        gates = self.plan(['Sources/JotCore/TranscriptExport.swift'])
        self.assertEqual(names(gates), ['portable', 'swift-test', 'app-build', 'recovery-checks'])

    def test_test_only_and_build_configuration_changes(self):
        self.assertEqual(names(self.plan(['Tests/JotCoreTests/TranscriptExportTests.swift'])), ['portable', 'swift-test'])
        self.assertEqual(names(self.plan(['project.yml'])), ['portable', 'app-build', 'recovery-checks'])
        self.assertEqual(names(self.plan(['Resources/Info.plist'])), ['portable', 'app-build'])
        self.assertEqual(names(self.plan(['SourcesExtra.md'])), ['portable'])

    def test_filters_run_before_the_full_suite(self):
        gate = self.plan(['docs/PLAN.md'], filters=['TranscriptExportTests'])[1]
        self.assertEqual(gate.steps, [['swift', 'test', '--filter', 'TranscriptExportTests'], ['swift', 'test']])

    @patch.object(check.platform, 'system', return_value='Linux')
    def test_mac_gates_are_unavailable_elsewhere(self, system):
        gates = self.plan(['Sources/Jot/SessionLibrary.swift'], skip={'portable'})
        self.assertEqual([gate.status for gate in gates], ['skipped', 'unavailable', 'unavailable', 'unavailable'])

    def test_verdict(self):
        gate = lambda status: check.Gate('g', 'G', [], status=status)
        self.assertEqual(check.verdict([gate('passed')]), 'PASS')
        self.assertEqual(check.verdict([gate('passed'), gate('unavailable')]), 'INCOMPLETE')
        self.assertEqual(check.verdict([gate('skipped'), gate('failed')]), 'FAIL')

    def test_posting_requires_a_verified_open_pr_at_the_checked_head(self):
        check.require_postable_head({'state': 'OPEN', 'headRefOid': 'checked'}, 'checked')
        for info in (None, {'state': 'OPEN', 'headRefOid': 'other'},
                     {'state': 'MERGED', 'headRefOid': 'checked'}):
            with self.subTest(info=info), self.assertRaises(SystemExit):
                check.require_postable_head(info, 'checked')

    def test_report_binds_the_head_and_hides_the_home_directory(self):
        home = str(Path.home())
        gate = check.Gate('swift-test', 'Swift', [['swift', 'test']], status='failed', tail=[f'{home}/x.swift: error'])
        context = {'pr': 5, 'head': 'a' * 40, 'branch': 'topic', 'base': 'main', 'mergeBase': 'b' * 40,
                   'files': ['Sources/Jot/A.swift'], 'machine': 'test'}
        report = check.render(context, [gate], 'FAIL', note='looked at it')
        self.assertIn(f'<!-- jot-local-check verdict=FAIL head={"a" * 40} pr=5 -->', report)
        self.assertIn('~/x.swift: error', report)
        self.assertNotIn(home + '/', report)
        self.assertIn('Reviewer note: looked at it', report)

    def test_public_report_never_contains_raw_logs_notes_or_machine_details(self):
        gate = check.Gate('swift-test', 'Swift', [], status='failed',
                          note='secret failure', tail=['private transcript', 'token=secret'])
        context = {'pr': 5, 'head': 'a' * 40, 'baseHead': 'b' * 40, 'machine': 'private machine', 'baseContained': False}
        report = check.public_report(context, [gate], 'FAIL')
        self.assertIn('| Swift | failed |', report)
        self.assertIn('diagnostic head-only results', report)
        for private in ('secret', 'transcript', 'private machine'):
            self.assertNotIn(private, report)

    def test_fork_provenance_is_fail_closed_unless_explicitly_reviewed(self):
        for info in (None, {}, {'isCrossRepository': None}, {'isCrossRepository': True}):
            with self.subTest(info=info), self.assertRaises(SystemExit):
                check.require_pr_metadata(info)
            check.require_pr_metadata(info, allow_fork=True)
        check.require_pr_metadata({'isCrossRepository': False})

    def test_attestation_requires_exact_head_base_reviewer_and_passed_checks(self):
        context = {'head': 'a' * 40, 'baseHead': 'b' * 40}
        required = {'app-behavior', 'real-model-audio'}
        data = dict(context, reviewer='Local tester', checks={name: {'result': 'passed', 'details': 'Actual check'}
                                                             for name in required})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'attestation.json'
            path.write_text(json.dumps(data))
            self.assertTrue(check.read_attestation(path, context, required))
            for field, bad in (('head', 'c' * 40), ('baseHead', 'c' * 40), ('reviewer', ''), ('checks', {})):
                path.write_text(json.dumps(dict(data, **{field: bad})))
                self.assertFalse(check.read_attestation(path, context, required))
            for result in ('skipped', 'failed', 'not-run'):
                data['checks']['app-behavior']['result'] = result
                path.write_text(json.dumps(data))
                self.assertFalse(check.read_attestation(path, context, required))
            path.write_text('not JSON')
            self.assertFalse(check.read_attestation(path, context, required))
        self.assertFalse(check.read_attestation(None, context, required))

    def test_manual_checks_are_conservative_and_include_real_audio_for_pipeline(self):
        self.assertEqual(check.manual_checks(['README.md', 'Tests/Test.swift']), set())
        self.assertEqual(check.manual_checks(['Resources/Info.plist']), {'app-behavior'})
        self.assertEqual(check.manual_checks(['Sources/Jot/SpeechPipeline.swift']),
                         {'app-behavior', 'real-model-audio'})
        for path in ('Sources/Jot/Transcriber.swift', 'Sources/JotCore/TranscriptionTuning.swift',
                     'Sources/JotCore/RecognitionCommitWindow.swift', 'Sources/JotCore/ListeningState.swift',
                     'scripts/check-recovery-flow.swift', 'scripts/check-capture-flow.swift', 'Package.resolved'):
            with self.subTest(path=path):
                self.assertIn('real-model-audio', check.manual_checks([path]))

    @patch.object(check.platform, 'system', return_value='Darwin')
    def test_native_verdict_cannot_pass_missing_skipped_unavailable_or_planned_gates(self, system):
        context = {'files': [], 'baseContained': True}
        for bad in ('skipped', 'unavailable', 'planned', 'unknown'):
            gates = [check.Gate(name, name, [], status='passed') for name in check.GATES]
            gates[-1].status = bad
            self.assertEqual(check.native_verdict(gates, context, None), 'INCOMPLETE')
        self.assertEqual(check.native_verdict([], context, None), 'INCOMPLETE')
        gates = [check.Gate(name, name, [], status='passed') for name in check.GATES]
        self.assertEqual(check.native_verdict(gates, context, None), 'PASS')
        for base_state in (False, None):
            self.assertEqual(check.native_verdict(gates, dict(context, baseContained=base_state), None), 'INCOMPLETE')

    @patch.object(check.subprocess, 'run')
    def test_status_payload_is_sha_bound_and_contains_no_logs_or_attestation_details(self, run):
        run.return_value = subprocess.CompletedProcess([], 0)
        context = {'url': 'https://github.com/StoneHub/jot/pull/5', 'head': 'a' * 40, 'baseHead': 'b' * 40}
        check.publish_status(Path('/tmp'), context, 'success')
        command = run.call_args.args[0]
        self.assertIn(f'repos/StoneHub/jot/statuses/{"a" * 40}', command)
        self.assertIn('context=jot/local-macos-validation', command)
        self.assertIn('state=success', command)
        self.assertIn(f'description=All native gates and required attestations passed; base {"b" * 40}', command)
        run.return_value = subprocess.CompletedProcess([], 1, stderr='private API failure')
        with self.assertRaisesRegex(SystemExit, 'publication failed or is uncertain'):
            check.publish_status(Path('/tmp'), context, 'error')
        self.assertEqual(run.call_count, 2)  # One attempt for each action; no automatic retries.

    @patch.object(check.subprocess, 'run')
    def test_status_refuses_invalid_pr_url_or_sha(self, run):
        for url, head in (('https://evil.invalid/StoneHub/jot/pull/5', 'a' * 40),
                          ('https://github.com/StoneHub/jot/pull/5', 'topic')):
            with self.subTest(url=url, head=head), self.assertRaises(SystemExit):
                check.publish_status(Path('/tmp'), {'url': url, 'head': head, 'baseHead': 'b' * 40}, 'success')
        run.assert_not_called()

    @patch.object(check.subprocess, 'run', side_effect=OSError('unavailable'))
    def test_status_launch_error_is_incomplete_without_retry(self, run):
        context = {'url': 'https://github.com/StoneHub/jot/pull/5', 'head': 'a' * 40, 'baseHead': 'b' * 40}
        with self.assertRaisesRegex(SystemExit, 'could not run status publication'):
            check.publish_status(Path('/tmp'), context, 'success')
        self.assertEqual(run.call_count, 1)


class WorktreeTests(unittest.TestCase):
    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd or self.clone, env=GIT_ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        base = Path(self.directory.name)
        origin, self.clone = base / 'origin.git', base / 'clone'
        subprocess.run(['git', 'init', '--quiet', '--bare', str(origin)], env=GIT_ENV, check=True)
        subprocess.run(['git', 'init', '--quiet', '-b', 'main', str(self.clone)], env=GIT_ENV, check=True)
        (self.clone / '.gitignore').write_text('work/\n')
        (self.clone / 'README.md').write_text('base\n')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'base')
        self.git('remote', 'add', 'origin', str(origin))
        self.git('push', '--quiet', 'origin', 'main')

    def tearDown(self):
        self.directory.cleanup()

    def open_pull_request(self, number, text, path='README.md'):
        self.git('switch', '--quiet', '-c', f'topic-{number}', 'main')
        changed = self.clone / path
        changed.parent.mkdir(parents=True, exist_ok=True)
        changed.write_text(text)
        self.git('add', path)
        self.git('commit', '--quiet', '-m', 'change')
        self.git('push', '--quiet', 'origin', f'HEAD:refs/heads/topic-{number}', f'HEAD:refs/pull/{number}/head')
        head = self.git('rev-parse', 'HEAD')
        self.git('switch', '--quiet', 'main')
        return head

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), '--no-gh', '--allow-fork', *args], cwd=self.clone, env=GIT_ENV,
                              capture_output=True, text=True)

    def test_clean_pull_request_passes_in_its_own_worktree(self):
        head = self.open_pull_request(7, 'base\nclean change\n')
        result = self.run_check('7')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'verdict=PASS head={head} pr=7', result.stdout)
        self.assertIn('git push origin HEAD:topic-7', result.stdout)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.clone / 'work/pr-7'), head)
        self.assertEqual(self.git('branch', '--show-current'), 'main')
        report = next((self.clone / 'work/pr-checks').glob('pr-7-*/report.md')).read_text()
        self.assertIn('verdict=PASS', report)

    def test_whitespace_error_fails(self):
        self.open_pull_request(8, 'base\ntrailing space \n')
        result = self.run_check('8')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('verdict=FAIL', result.stdout)
        self.assertIn('trailing whitespace', result.stdout)

    def test_existing_worktree_is_reused_but_never_overwritten(self):
        self.open_pull_request(9, 'base\nfirst\n')
        self.assertEqual(self.run_check('9').returncode, 0)
        (self.clone / 'work/pr-9/README.md').write_text('local edit\n')
        result = self.run_check('9')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('has local changes', result.stderr)
        self.assertEqual((self.clone / 'work/pr-9/README.md').read_text(), 'local edit\n')

    def test_plain_directory_does_not_redirect_git_to_the_main_checkout(self):
        self.open_pull_request(10, 'base\nsecond\n')
        (self.clone / 'work/pr-10').mkdir(parents=True)
        result = self.run_check('10')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('is not a git worktree', result.stderr)
        self.assertEqual(self.git('branch', '--show-current'), 'main')

    def test_dry_run_changes_nothing(self):
        self.open_pull_request(11, 'base\nthird\n')
        result = self.run_check('11', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('- portable: always', result.stdout)
        self.assertFalse((self.clone / 'work').exists())

    def test_no_gh_without_reviewed_fork_opt_in_cannot_execute_pr(self):
        self.open_pull_request(12, 'base\nchange\n')
        result = subprocess.run([sys.executable, str(SCRIPT), '--no-gh', '12'], cwd=self.clone,
                                env=GIT_ENV, capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)
        self.assertIn('Cannot establish PR fork provenance', result.stderr)
        self.assertFalse((self.clone / 'work').exists())

    def test_fetch_failure_cannot_reuse_cached_base(self):
        self.open_pull_request(13, 'base\nchange\n')
        self.git('remote', 'set-url', 'origin', str(self.clone / 'missing.git'))
        result = self.run_check('13')
        self.assertEqual(result.returncode, 3)
        self.assertIn('stale local copy is not validation', result.stderr)
        self.assertNotIn('verdict=PASS', result.stdout)

    def test_dirty_current_checkout_is_incomplete_even_when_checks_pass(self):
        (self.clone / 'README.md').write_text('uncommitted\n')
        result = self.run_check('--current')
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn('verdict=INCOMPLETE', result.stdout)

    def test_initially_dirty_current_checkout_restored_by_a_gate_stays_incomplete(self):
        (self.clone / 'README.md').write_text('uncommitted input\n')
        def restored(gate, tree, logs, expected_head=None):
            self.assertIsNone(expected_head)
            self.git('restore', '.', cwd=tree)
            gate.status = 'passed'
        cwd = Path.cwd()
        try:
            os.chdir(self.clone)
            with patch.object(check, 'run_gate', side_effect=restored), patch.object(check, 'machine', return_value='test'), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(check.main(['--current', '--no-gh']), 3)
        finally:
            os.chdir(cwd)
        self.assertFalse(self.git('status', '--porcelain'))
        report = next((self.clone / 'work/pr-checks').glob('current-*/report.json'))
        self.assertEqual(json.loads(report.read_text())['verdict'], 'INCOMPLETE')

    def simulated_status_run(self, number, *args, run_gate=None, info_change=None, system='Darwin', publisher=None):
        """Exercise real git snapshots and main orchestration, but never execute native commands or post status."""
        head = self.git('rev-parse', f'refs/heads/topic-{number}')
        base = self.git('rev-parse', 'refs/heads/main')
        info = {'number': number, 'url': f'https://github.com/StoneHub/jot/pull/{number}', 'state': 'OPEN',
                'headRefName': f'topic-{number}', 'headRefOid': head, 'baseRefName': 'main', 'baseRefOid': base,
                'isCrossRepository': False}
        if info_change:
            info.update(info_change)
        def passed(gate, tree, logs, expected_head=None):
            gate.status = 'passed'
        cwd = Path.cwd()
        try:
            os.chdir(self.clone)
            with ExitStack() as stack:
                stack.enter_context(patch.object(check, 'gh_pr', return_value=info))
                stack.enter_context(patch.object(check, 'machine', return_value='Simulated test environment'))
                stack.enter_context(patch.object(check.platform, 'system', return_value=system))
                stack.enter_context(patch.object(check.shutil, 'which', return_value='/mock/tool'))
                stack.enter_context(patch.object(check, 'run_gate', side_effect=run_gate or passed))
                publication = stack.enter_context(patch.object(check, 'publish_status', side_effect=publisher))
                stack.enter_context(redirect_stdout(io.StringIO()))
                stack.enter_context(redirect_stderr(io.StringIO()))
                try:
                    result = check.main([str(number), '--publish-status', *args])
                except (SystemExit, KeyboardInterrupt) as error:
                    result = error
                return result, [call.args[2] for call in publication.call_args_list]
        finally:
            os.chdir(cwd)

    def test_simulated_status_success_requires_all_gates(self):
        self.open_pull_request(20, 'base\nchange\n')
        result, states = self.simulated_status_run(20)
        self.assertEqual(result, 0)
        self.assertEqual(states, ['pending', 'success'])

    def test_simulated_linux_never_publishes_success(self):
        self.open_pull_request(21, 'base\nchange\n')
        result, states = self.simulated_status_run(21, system='Linux')
        self.assertEqual(result, 3)
        self.assertEqual(states, ['pending', 'error'])

    def test_simulated_skip_and_dry_run_never_publish_any_status(self):
        self.open_pull_request(22, 'base\nchange\n')
        for args in (('--skip', 'app-build'), ('--dry-run',)):
            result, states = self.simulated_status_run(22, *args)
            self.assertIsInstance(result, SystemExit)
            self.assertEqual(states, [])

    def test_simulated_failed_gate_reports_failure(self):
        self.open_pull_request(23, 'base\nchange\n')
        def failed(gate, tree, logs, expected_head=None):
            gate.status = 'failed' if gate.name == 'app-build' else 'passed'
        result, states = self.simulated_status_run(23, run_gate=failed)
        self.assertEqual(result, 1)
        self.assertEqual(states, ['pending', 'failure'])

    def test_simulated_cancel_invalidates_pending_without_success(self):
        self.open_pull_request(24, 'base\nchange\n')
        def cancelled(gate, tree, logs, expected_head=None):
            raise KeyboardInterrupt
        result, states = self.simulated_status_run(24, run_gate=cancelled)
        self.assertIsInstance(result, KeyboardInterrupt)
        self.assertEqual(states, ['pending', 'error'])
        self.assert_local_report_incomplete(24)

    def assert_local_report_incomplete(self, number):
        report = next((self.clone / 'work/pr-checks').glob(f'pr-{number}-*/report.json'))
        self.assertEqual(json.loads(report.read_text())['verdict'], 'INCOMPLETE')
        self.assertIn('verdict=INCOMPLETE', report.with_suffix('.md').read_text())

    def test_transient_worktree_mutation_between_gates_cannot_pass(self):
        self.open_pull_request(33, 'base\nchange\n')
        visited = []
        def transient(gate, tree, logs, expected_head=None):
            visited.append(gate.name)
            gate.status = 'passed'
            if gate.name == 'portable':
                (tree / 'README.md').write_text('wrong content for intermediate checks\n')
            elif gate.name == 'recovery-checks':
                self.git('restore', '.', cwd=tree)
        result, states = self.simulated_status_run(33, run_gate=transient)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, ['pending', 'error'])
        self.assertEqual(visited, ['portable'])
        self.assert_local_report_incomplete(33)

    def test_run_gate_stops_after_a_step_mutates_the_checked_tree(self):
        head = self.git('rev-parse', 'HEAD')
        logs = self.clone / 'work/step-logs'
        logs.mkdir(parents=True)
        gate = check.Gate('portable', 'Portable', [
            [sys.executable, '-c', "from pathlib import Path; Path('README.md').write_text('changed\\n')"],
            ['git', 'restore', '.']])
        with self.assertRaisesRegex(SystemExit, 'worktree is dirty'):
            check.run_gate(gate, self.clone, logs, expected_head=head)
        self.assertEqual((self.clone / 'README.md').read_text(), 'changed\n')
        self.assertNotIn('$ git restore .', (logs / 'portable.log').read_text())

    def test_simulated_head_base_and_worktree_races_never_publish_success(self):
        self.open_pull_request(25, 'base\nchange\n')
        for race in ('head', 'base', 'dirty', 'checkout'):
            # Restore the remote refs between independent race scenarios.
            self.git('push', '--quiet', 'origin', '+main:refs/heads/main',
                     '+topic-25:refs/pull/25/head')
            tree = self.clone / 'work/pr-25'
            if tree.exists():
                self.git('checkout', '--quiet', '--detach', 'topic-25', cwd=tree)
                self.git('restore', '.', cwd=tree)
            def raced(gate, checked_tree, logs, expected_head=None):
                gate.status = 'passed'
                if gate.name != 'portable':
                    return
                if race == 'head':
                    self.git('push', '--quiet', 'origin', '+main:refs/pull/25/head')
                elif race == 'base':
                    self.git('push', '--quiet', 'origin', '+topic-25:refs/heads/main')
                elif race == 'dirty':
                    (checked_tree / 'README.md').write_text('changed during checks\n')
                else:
                    self.git('checkout', '--quiet', '--detach', 'main', cwd=checked_tree)
            result, states = self.simulated_status_run(25, run_gate=raced)
            self.assertIsInstance(result, SystemExit, race)
            self.assertEqual(states, ['pending', 'error'], race)

    def test_simulated_stale_metadata_and_fetch_failure_never_publish_status(self):
        self.open_pull_request(26, 'base\nchange\n')
        for metadata in ({'headRefOid': 'a' * 40}, {'baseRefOid': 'b' * 40}, {'isCrossRepository': None}):
            result, states = self.simulated_status_run(26, info_change=metadata)
            self.assertIsInstance(result, SystemExit)
            self.assertEqual(states, [])
        self.git('remote', 'set-url', 'origin', str(self.clone / 'missing.git'))
        result, states = self.simulated_status_run(26)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, [])

    def test_simulated_publication_failure_is_not_retried(self):
        self.open_pull_request(27, 'base\nchange\n')
        def unavailable(root, context, state):
            raise SystemExit('INCOMPLETE: status API unavailable')
        result, states = self.simulated_status_run(27, publisher=unavailable)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, ['pending'])
        self.assert_local_report_incomplete(27)

    def test_simulated_app_change_needs_matching_manual_attestation(self):
        head = self.open_pull_request(28, '<plist/>\n', 'Resources/Info.plist')
        result, states = self.simulated_status_run(28)
        self.assertEqual(result, 3)
        self.assertEqual(states, ['pending', 'error'])
        path = self.clone.parent / 'attestation.json'
        path.write_text(json.dumps({'head': head, 'baseHead': self.git('rev-parse', 'main'),
                                   'reviewer': 'Local tester',
                                   'checks': {'app-behavior': {'result': 'passed', 'details': 'Exercised status UI'}}}))
        result, states = self.simulated_status_run(28, '--ui-attestation', str(path))
        self.assertEqual(result, 0)
        self.assertEqual(states, ['pending', 'success'])
        data = json.loads(path.read_text())
        data['head'] = 'a' * 40
        path.write_text(json.dumps(data))
        result, states = self.simulated_status_run(28, '--ui-attestation', str(path))
        self.assertEqual(result, 3)
        self.assertEqual(states, ['pending', 'error'])

    def test_simulated_attestation_mutation_during_success_is_revoked(self):
        head = self.open_pull_request(29, '<plist/>\n', 'Resources/Info.plist')
        path = self.clone.parent / 'attestation.json'
        path.write_text(json.dumps({'head': head, 'baseHead': self.git('rev-parse', 'main'),
                                   'reviewer': 'Local tester',
                                   'checks': {'app-behavior': {'result': 'passed', 'details': 'Exercised status UI'}}}))
        def changed(root, context, state):
            if state == 'success':
                path.write_text('{}')
        result, states = self.simulated_status_run(29, '--ui-attestation', str(path), publisher=changed)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, ['pending', 'success', 'error'])
        self.assert_local_report_incomplete(29)

    def test_simulated_base_move_during_success_is_revoked(self):
        self.open_pull_request(30, 'base\nchange\n')
        def moved(root, context, state):
            if state == 'success':
                self.git('push', '--quiet', 'origin', '+topic-30:refs/heads/main')
        result, states = self.simulated_status_run(30, publisher=moved)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, ['pending', 'success', 'error'])
        self.assert_local_report_incomplete(30)

    def test_simulated_failure_to_publish_success_is_not_retried_or_reported_successfully(self):
        self.open_pull_request(31, 'base\nchange\n')
        def unavailable(root, context, state):
            if state == 'success':
                raise SystemExit('INCOMPLETE: status publication uncertain')
        result, states = self.simulated_status_run(31, publisher=unavailable)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(states, ['pending', 'success'])  # One attempted success write; never retried.
        self.assert_local_report_incomplete(31)

    def test_simulated_transcriber_change_without_real_model_check_cannot_pass(self):
        head = self.open_pull_request(32, 'fake Swift\n', 'Sources/Jot/Transcriber.swift')
        path = self.clone.parent / 'attestation.json'
        data = {'head': head, 'baseHead': self.git('rev-parse', 'main'), 'reviewer': 'Local tester',
                'checks': {'app-behavior': {'result': 'passed', 'details': 'Exercised UI only'}}}
        path.write_text(json.dumps(data))
        result, states = self.simulated_status_run(32, '--ui-attestation', str(path))
        self.assertEqual(result, 3)
        self.assertEqual(states, ['pending', 'error'])
        data['checks']['real-model-audio'] = {'result': 'passed', 'details': 'Ran actual model recovery check'}
        path.write_text(json.dumps(data))
        result, states = self.simulated_status_run(32, '--ui-attestation', str(path))
        self.assertEqual(result, 0)
        self.assertEqual(states, ['pending', 'success'])

    def test_public_comment_is_deferred_until_status_verified_and_omitted_after_race(self):
        self.open_pull_request(34, 'base\nchange\n')
        events = []
        real_run = subprocess.run
        def subprocess_with_comment(command, **kwargs):
            if command[:3] == ['gh', 'pr', 'comment']:
                events.append('comment')
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **kwargs)
        def record(root, context, state):
            events.append(state)
        with patch.object(check.subprocess, 'run', side_effect=subprocess_with_comment):
            result, states = self.simulated_status_run(34, '--post', publisher=record)
        self.assertEqual(result, 0)
        self.assertEqual(events, ['pending', 'success', 'comment'])
        events.clear()
        def moved(root, context, state):
            events.append(state)
            if state == 'success':
                self.git('push', '--quiet', 'origin', '+topic-34:refs/heads/main')
        with patch.object(check.subprocess, 'run', side_effect=subprocess_with_comment):
            result, states = self.simulated_status_run(34, '--post', publisher=moved)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(events, ['pending', 'success', 'error'])
        self.assert_local_report_incomplete(34)

    def advance_base(self, number, from_pr=False):
        self.git('switch', '--quiet', '-c', f'advanced-{number}', f'topic-{number}' if from_pr else 'main')
        (self.clone / 'base-addition.txt').write_text(f'new base content {number}\n')
        self.git('add', 'base-addition.txt')
        self.git('commit', '--quiet', '-m', 'advance base')
        self.git('push', '--quiet', 'origin', 'HEAD:refs/heads/main')
        self.git('switch', '--quiet', 'main')
        self.git('merge', '--quiet', '--ff-only', f'advanced-{number}')

    def test_status_refuses_advanced_and_divergent_current_bases(self):
        for number, from_pr in ((35, True), (36, False)):
            head = self.open_pull_request(number, f'base\nchange {number}\n')
            self.advance_base(number, from_pr=from_pr)
            base = self.git('rev-parse', 'main')
            self.assertFalse(check.contains_base(self.clone, base, head))
            result, states = self.simulated_status_run(number)
            self.assertIsInstance(result, SystemExit)
            self.assertIn('does not contain the current base', str(result))
            self.assertEqual(states, [])
            self.assert_local_report_incomplete(number)

    def test_outdated_base_nonpublishing_check_is_explicitly_head_only(self):
        self.open_pull_request(37, 'base\nchange\n')
        self.advance_base(37)
        result = self.run_check('37')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('diagnostic head-only results', result.stdout)
        self.assertIn('native status publication requires an updated head', result.stdout)


if __name__ == '__main__':
    unittest.main()
