"""Choose local signing freely while keeping official Jot releases owner-signed."""
import os
import re
import subprocess

OWNER_TEAM = 'N6GPP46885'
OWNER_DEVELOPMENT_IDENTITY = 'Apple Development: monroes.awesome@gmail.com (Y33U865KBQ)'


def installed_identities():
    output = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    return re.findall(r'"([^"]+)"', output)


def certificate_team(identity):
    certificate = subprocess.check_output(['security', 'find-certificate', '-c', identity, '-p'])
    subject = subprocess.check_output(
        ['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], input=certificate, text=False
    ).decode()
    match = re.search(r'(?:^|,)OU=([^,]+)', subject)
    if not match:
        raise SystemExit(f'Cannot read a team ID from signing certificate: {identity}. Set JOT_SIGN_TEAM.')
    return match.group(1)


def local_signing_configuration():
    """Use an explicit identity, Monroe's development identity, or another installed identity."""
    identities = installed_identities()
    identity = os.environ.get('JOT_SIGN_IDENTITY')
    if not identity:
        identity = OWNER_DEVELOPMENT_IDENTITY if OWNER_DEVELOPMENT_IDENTITY in identities else next(
            (candidate for candidate in identities if candidate.startswith(('Apple Development:', 'Developer ID Application:'))),
            None)
    if not identity:
        raise SystemExit('No usable signing identity is installed. Set JOT_SIGN_IDENTITY and JOT_SIGN_TEAM.')
    if identity not in identities:
        raise SystemExit(f'Jot signing identity is unavailable: {identity}.')
    team = os.environ.get('JOT_SIGN_TEAM') or certificate_team(identity)
    return identity, team


def official_signing_configuration():
    """Require Monroe's Developer ID certificate for a public Jot release."""
    identities = installed_identities()
    requested = os.environ.get('JOT_SIGN_IDENTITY')
    candidates = [identity for identity in identities
                  if identity.startswith('Developer ID Application:') and certificate_team(identity) == OWNER_TEAM]
    identity = requested or (candidates[0] if candidates else None)
    if not identity or identity not in candidates:
        raise SystemExit(
            f'Official Jot releases require a Developer ID Application certificate for owner team {OWNER_TEAM}.')
    team = os.environ.get('JOT_SIGN_TEAM', OWNER_TEAM)
    if team != OWNER_TEAM:
        raise SystemExit(f'Official Jot releases must use owner team {OWNER_TEAM}, not {team}.')
    return identity, team


def verify_signing_team(bundle, expected_team):
    result = subprocess.run(['codesign', '-dv', str(bundle)], capture_output=True, text=True, check=True)
    if f'TeamIdentifier={expected_team}' not in result.stderr.splitlines():
        raise SystemExit(f'{bundle} is not signed by expected team {expected_team}.')
    return expected_team
