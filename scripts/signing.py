"""Jot belongs to Monroe; local builds and releases use the same signing team."""
import os
import subprocess

TEAM = 'N6GPP46885'
IDENTITY = 'Apple Development: monroes.awesome@gmail.com (Y33U865KBQ)'


def signing_configuration():
    team = os.environ.get('JOT_SIGN_TEAM', TEAM)
    if team != TEAM:
        raise SystemExit(f'Jot must be signed by Monroe’s team {TEAM}, not {team}.')
    identity = os.environ.get('JOT_SIGN_IDENTITY', IDENTITY)
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    if f'"{identity}"' not in identities:
        raise SystemExit(f'Jot signing identity is unavailable: {identity}. Install Monroe’s certificate and private key.')
    return identity, team


def verify_signing_team(bundle):
    result = subprocess.run(['codesign', '-dv', str(bundle)], capture_output=True, text=True, check=True)
    if f'TeamIdentifier={TEAM}' not in result.stderr.splitlines():
        raise SystemExit(f'{bundle} is not signed by Jot’s owner team {TEAM}; refusing to install or release it.')
    return TEAM
