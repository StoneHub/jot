import importlib.util
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

    def open_pull_request(self, number, text):
        self.git('switch', '--quiet', '-c', f'topic-{number}', 'main')
        (self.clone / 'README.md').write_text(text)
        self.git('commit', '--quiet', '-am', 'change')
        self.git('push', '--quiet', 'origin', f'HEAD:refs/heads/topic-{number}', f'HEAD:refs/pull/{number}/head')
        head = self.git('rev-parse', 'HEAD')
        self.git('switch', '--quiet', 'main')
        return head

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), '--no-gh', *args], cwd=self.clone, env=GIT_ENV,
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


if __name__ == '__main__':
    unittest.main()
