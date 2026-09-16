import subprocess
import unittest
from unittest.mock import patch

from signing import (OWNER_DEVELOPMENT_IDENTITY, OWNER_TEAM, local_signing_configuration,
                     official_signing_configuration, verify_signing_team)


class SigningTests(unittest.TestCase):
    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.certificate_team', return_value=OWNER_TEAM)
    @patch('signing.installed_identities')
    def test_local_build_prefers_owner_development_identity_when_available(self, identities, certificate_team):
        identities.return_value = ['Developer ID Application: Other Owner (OTHERTEAM)', OWNER_DEVELOPMENT_IDENTITY]
        self.assertEqual(local_signing_configuration(), (OWNER_DEVELOPMENT_IDENTITY, OWNER_TEAM))

    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.certificate_team', return_value='OTHERTEAM')
    @patch('signing.installed_identities', return_value=['Apple Development: Contributor (CERTIFICATEID)'])
    def test_contributor_can_build_with_their_identity(self, identities, certificate_team):
        self.assertEqual(local_signing_configuration(), ('Apple Development: Contributor (CERTIFICATEID)', 'OTHERTEAM'))

    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.certificate_team', return_value='OTHERTEAM')
    @patch('signing.installed_identities', return_value=['Developer ID Application: Other Owner (OTHERTEAM)'])
    def test_official_release_requires_owner_developer_id(self, identities, certificate_team):
        with self.assertRaises(SystemExit):
            official_signing_configuration()

    @patch.dict('os.environ', {}, clear=True)
    @patch('signing.certificate_team', return_value=OWNER_TEAM)
    @patch('signing.installed_identities')
    def test_official_release_accepts_owner_developer_id(self, identities, certificate_team):
        identity = f'Developer ID Application: Monroe Stone ({OWNER_TEAM})'
        identities.return_value = [identity]
        self.assertEqual(official_signing_configuration(), (identity, OWNER_TEAM))

    @patch('signing.subprocess.run')
    def test_actual_product_team_is_required(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, '', 'TeamIdentifier=OTHERTEAM\n')
        with self.assertRaises(SystemExit):
            verify_signing_team('Jot.app', OWNER_TEAM)
        run.return_value.stderr = f'TeamIdentifier={OWNER_TEAM}\n'
        self.assertEqual(verify_signing_team('Jot.app', OWNER_TEAM), OWNER_TEAM)


if __name__ == '__main__':
    unittest.main()
