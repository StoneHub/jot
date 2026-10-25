"""Notarization steps for official releases, with notarytool, stapler, codesign and spctl mocked."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import notarization


def completed(command, returncode=0, stdout='', stderr=''):
    return subprocess.CompletedProcess(command, returncode, stdout, stderr)


class NotarizationTests(unittest.TestCase):
    def test_profile_defaults_to_the_documented_name_and_can_be_overridden(self):
        self.assertEqual(notarization.notary_profile({}), 'jot-notary')
        self.assertEqual(notarization.notary_profile({'JOT_NOTARY_PROFILE': ''}), 'jot-notary')
        self.assertEqual(notarization.notary_profile({'JOT_NOTARY_PROFILE': 'other'}), 'other')

    def test_missing_profile_stops_with_the_setup_pointer(self):
        error = 'Error: No Keychain password item found for profile: jot-notary'
        with patch('notarization.subprocess.run', return_value=completed([], 69, '', error + '\n')):
            with self.assertRaises(SystemExit) as stopped:
                notarization.check_profile('jot-notary')
        self.assertIn(error, str(stopped.exception))
        self.assertIn('Notarization setup', str(stopped.exception))
        self.assertIn('--local', str(stopped.exception))

    def test_accepted_submission_returns_its_id(self):
        result = completed([], 0, json.dumps(dict(id='abc', status='Accepted')))
        with patch('notarization.subprocess.run', return_value=result) as run:
            self.assertEqual(notarization.submit(Path('Jot-1.0.0.zip'), 'jot-notary'), 'abc')
        self.assertEqual(run.call_args.args[0], ['xcrun', 'notarytool', 'submit', 'Jot-1.0.0.zip', '--keychain-profile',
                                                 'jot-notary', '--wait', '--output-format', 'json'])

    def test_rejected_submission_prints_apples_log_and_stops(self):
        def run(command, **kwargs):
            if command[2] == 'submit':
                return completed(command, 0, json.dumps(dict(id='abc', status='Invalid')))
            return completed(command, 0, '{"issues": ["The binary is not signed with a valid Developer ID certificate."]}')

        errors = io.StringIO()
        with patch('notarization.subprocess.run', side_effect=run) as mocked, contextlib.redirect_stderr(errors):
            with self.assertRaises(SystemExit) as stopped:
                notarization.submit(Path('Jot-1.0.0.zip'), 'jot-notary')
        self.assertEqual(mocked.call_args.args[0], ['xcrun', 'notarytool', 'log', 'abc', '--keychain-profile', 'jot-notary'])
        self.assertIn('valid Developer ID', errors.getvalue())
        self.assertIn('Invalid', str(stopped.exception))

    def test_submission_that_never_starts_reports_notarytool_output(self):
        errors = io.StringIO()
        with patch('notarization.subprocess.run', return_value=completed([], 1, '', 'Error: HTTP status code: 401\n')), \
                contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as stopped:
            notarization.submit(Path('Jot-1.0.0.zip'), 'jot-notary')
        self.assertIn('401', str(stopped.exception))
        self.assertIn('not created', str(stopped.exception))

    def test_stapled_app_must_be_notarized_for_gatekeeper(self):
        app = Path('build/Jot.app')
        for verdict, accepted in (('source=Notarized Developer ID', True), ('source=Developer ID', False)):
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return completed(command, 0, '', f'{app}: accepted\n{verdict}\n' if command[0] == 'spctl' else '')

            with self.subTest(verdict=verdict), patch('notarization.subprocess.run', side_effect=run):
                if accepted:
                    notarization.staple_and_verify(app)
                else:
                    with self.assertRaises(SystemExit):
                        notarization.staple_and_verify(app)
                self.assertEqual([command[:2] for command in commands],
                                 [['xcrun', 'stapler'], ['xcrun', 'stapler'], ['codesign', '--verify'], ['spctl', '--assess']])

    def test_failed_staple_stops_before_verification(self):
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            return completed(command, 65, '', 'Could not find base64 encoded ticket')

        with patch('notarization.subprocess.run', side_effect=run), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                notarization.staple_and_verify(Path('build/Jot.app'))
        self.assertEqual(len(commands), 1)


if __name__ == '__main__':
    unittest.main()
