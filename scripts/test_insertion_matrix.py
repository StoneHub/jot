"""The insertion matrix proof: bound to one commit, every row passed, and the release check reads it."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import insertion_matrix  # noqa: E402

HEAD = 'a' * 40


def passing_rows(**overrides):
    rows = []
    for name in insertion_matrix.ROWS:
        row = dict(target=name, expected='refused' if name == 'password' else 'verified', result='passed',
                   path=None if name == 'password' else 'accessibility', outcome=None if name == 'password' else 'verified')
        row.update(overrides.get(name, {}))
        rows.append(row)
    return rows


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.proof = Path(self.temp.name) / 'insertion-matrix.json'

    def write(self, rows, head=HEAD, dirty=False):
        self.proof.write_text(json.dumps(insertion_matrix.proof_document(dict(phrase='p', rows=rows), head, dirty, machine='m', checked_at='t')))

    def test_every_row_passed_on_the_same_commit_is_a_proof(self):
        self.write(passing_rows())
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), [])

    def test_missing_invalid_or_foreign_files_are_not_proofs(self):
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), [f'no matrix report at {self.proof}'])
        self.proof.write_text('{not json')
        self.assertEqual(len(insertion_matrix.proof_problems(self.proof, HEAD)), 1)
        self.proof.write_text(json.dumps(dict(head=HEAD)))
        self.assertEqual(len(insertion_matrix.proof_problems(self.proof, HEAD)), 1)

    def test_another_commit_or_a_dirty_tree_does_not_count(self):
        self.write(passing_rows(), head='b' * 40)
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), ['the report is for commit bbbbbbb, not aaaaaaa'])
        self.write(passing_rows(), dirty=True)
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), ['the report was made on a tree with uncommitted changes'])

    def test_a_failed_skipped_or_missing_row_names_itself(self):
        self.write(passing_rows(terminal=dict(result='failed', outcome='dispatched_not_verified', note='delivery not verified'),
                                electron=dict(result='skipped', note='pass --electron <bundle id>')))
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD),
                         ['row terminal failed: delivery not verified', 'row electron skipped: pass --electron <bundle id>'])
        self.write([row for row in passing_rows() if row['target'] != 'password'])
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), ['row password is missing'])

    def test_a_password_field_that_took_text_fails_even_when_delivery_verified(self):
        self.write(passing_rows(password=dict(result='failed', verified=True, note='a password field accepted text')))
        self.assertEqual(insertion_matrix.proof_problems(self.proof, HEAD), ['row password failed: a password field accepted text'])

    def test_table_lists_every_row_without_field_contents(self):
        text = insertion_matrix.table(passing_rows(terminal=dict(role='AXTextArea', path='unicode_hid')))
        self.assertEqual(text.count('\n'), 1 + len(insertion_matrix.ROWS))
        self.assertIn('| terminal | verified | passed | unicode_hid | verified | AXTextArea |', text)
        self.assertIn('| password | refused | passed | – | – | – |', text)

    def test_run_passes_the_electron_skip_and_phrase_options_through(self):
        with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 1)) as run:
            code = insertion_matrix.run_matrix(Path('/tool'), Path('/r.json'), 'com.example.App', 'n', ['terminal'], 'Hello.')
        self.assertEqual(code, 1)
        self.assertEqual(run.call_args.args[0], ['/tool', '--insertion-matrix', '--out', '/r.json', '--electron', 'com.example.App',
                                                '--electron-new', 'n', '--skip', 'terminal', '--phrase', 'Hello.'])


class MainTests(unittest.TestCase):
    """The command line: git binds the proof to HEAD; a failed row keeps the report but exits 1."""

    def setUp(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        os.chdir(self.root)
        self.binary = self.root / 'JotRecoveryChecks'
        self.binary.write_text('#!/bin/sh\n')
        self.binary.chmod(0o755)
        self.rows = passing_rows()
        self.dirty = ''

    def fake_output(self, command, **kwargs):
        if command[:3] == ['git', 'rev-parse', '--show-toplevel']:
            return str(self.root) + '\n'
        if command[:3] == ['git', 'rev-parse', 'HEAD']:
            return HEAD + '\n'
        if command[:3] == ['git', 'status', '--porcelain']:
            return self.dirty
        raise AssertionError(command)

    def fake_run(self, command, **kwargs):
        Path(command[command.index('--out') + 1]).write_text(json.dumps(dict(phrase='p', rows=self.rows)))
        return subprocess.CompletedProcess(command, 1 if any(r['result'] == 'failed' for r in self.rows) else 0)

    def run_main(self, *args):
        with patch('subprocess.check_output', side_effect=self.fake_output), patch('subprocess.run', side_effect=self.fake_run), \
                patch('platform.system', return_value='Darwin'), contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            code = insertion_matrix.main(['--binary', str(self.binary), *args])
        return code, out.getvalue()

    def test_a_passing_run_writes_a_proof_bound_to_head(self):
        code, output = self.run_main()
        self.assertEqual(code, 0)
        proof = json.loads((self.root / 'build/insertion-matrix.json').read_text())
        self.assertEqual((proof['head'], proof['dirty'], len(proof['rows'])), (HEAD, False, len(insertion_matrix.ROWS)))
        self.assertIn('| textedit | verified | passed |', output)
        self.assertEqual(insertion_matrix.proof_problems(self.root / 'build/insertion-matrix.json', HEAD), [])

    def test_a_failed_or_skipped_row_keeps_the_report_and_says_it_is_no_proof(self):
        self.rows = passing_rows(safari=dict(result='failed', note='delivery not verified'))
        code, output = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn('Not a release proof: row safari failed: delivery not verified.', output)
        self.assertTrue((self.root / 'build/insertion-matrix.json').exists())

    def test_a_dirty_tree_is_recorded_so_the_release_refuses_it(self):
        self.dirty = ' M Sources/Jot/DictationInput.swift\n'
        code, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertTrue(json.loads((self.root / 'build/insertion-matrix.json').read_text())['dirty'])

    def test_refuses_off_mac(self):
        with patch('platform.system', return_value='Linux'), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            insertion_matrix.main(['--binary', str(self.binary)])


if __name__ == '__main__':
    unittest.main()
