import subprocess
import unittest
from unittest.mock import patch

from signing import IDENTITY, TEAM, signing_configuration, verify_signing_team


class SigningTests(unittest.TestCase):
    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.subprocess.check_output')
    def test_unrelated_certificate_first_does_not_change_owner(self, output):
        output.return_value = f'1) "Developer ID Application: Other Owner (OTHERTEAM)"\n2) "{IDENTITY}"'
        self.assertEqual(signing_configuration(), (IDENTITY, TEAM))

    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.subprocess.check_output', return_value='1) "Developer ID Application: Other Owner (OTHERTEAM)"')
    def test_missing_owner_certificate_fails(self, output):
        with self.assertRaises(SystemExit):
            signing_configuration()

    @patch.dict('os.environ', {'JOT_SIGN_TEAM': 'OTHERTEAM'}, clear=True)
    def test_wrong_team_override_fails(self):
        with self.assertRaises(SystemExit):
            signing_configuration()

    @patch('signing.subprocess.run')
    def test_actual_product_team_is_required(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, '', 'TeamIdentifier=OTHERTEAM\n')
        with self.assertRaises(SystemExit):
            verify_signing_team('Jot.app')
        run.return_value.stderr = f'TeamIdentifier={TEAM}\n'
        self.assertEqual(verify_signing_team('Jot.app'), TEAM)


if __name__ == '__main__':
    unittest.main()
