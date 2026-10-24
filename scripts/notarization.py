"""Apple notarization for official Jot releases: check the stored credentials early, then submit, staple and verify."""
import json
import subprocess
import sys

# The keychain profile name the setup steps in docs/RELEASING.md create; JOT_NOTARY_PROFILE overrides it.
DEFAULT_PROFILE = 'jot-notary'
SETUP_HINT = 'See "Notarization setup" in docs/RELEASING.md, or pass --local for a development-signed pre-release.'


def notary_profile(environ):
    return environ.get('JOT_NOTARY_PROFILE') or DEFAULT_PROFILE


def last_line(result):
    lines = (result.stderr or result.stdout or '').strip().splitlines()
    return lines[-1] if lines else f'exit {result.returncode}'


def check_profile(profile):
    """Fail before the long test and build steps when the profile is missing or Apple rejects its credentials."""
    # history only reads past submissions, so dry runs can call it too.
    result = subprocess.run(['xcrun', 'notarytool', 'history', '--keychain-profile', profile, '--output-format', 'json'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f'Notary profile "{profile}" is missing or Apple refused it ({last_line(result)}). {SETUP_HINT}')


def submit(archive, profile):
    """Submit the ZIP and wait. Anything but Accepted prints Apple's issue log and stops the release."""
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile', profile,
                             '--wait', '--output-format', 'json'], capture_output=True, text=True)
    try:
        submission = json.loads(result.stdout)
    except json.JSONDecodeError:
        submission = {}
    status, identifier = submission.get('status'), submission.get('id')
    if result.returncode == 0 and status == 'Accepted':
        return identifier
    if identifier:
        log = subprocess.run(['xcrun', 'notarytool', 'log', identifier, '--keychain-profile', profile],
                             capture_output=True, text=True)
        print(log.stdout[-8000:] or log.stderr[-4000:], file=sys.stderr)
    else:
        print(result.stdout[-4000:], result.stderr[-4000:], sep='\n', file=sys.stderr)
    raise SystemExit(f'Apple notarization ended with {status or last_line(result)} '
                     f'(submission {identifier or "not created"}); the log above lists what Apple rejected.')


def staple_and_verify(app):
    """Staple the ticket, then require the signature and Gatekeeper to accept the app as notarized."""
    for command in (['xcrun', 'stapler', 'staple', str(app)],
                    ['xcrun', 'stapler', 'validate', str(app)],
                    ['codesign', '--verify', '--deep', '--strict', str(app)],
                    ['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)]):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout[-4000:], result.stderr[-4000:], sep='\n', file=sys.stderr)
            raise SystemExit(f'{" ".join(command[:2])} failed with exit {result.returncode}.')
    # spctl reports its verdict on stderr; a Developer ID app that is not notarized would say only "Developer ID".
    if 'source=Notarized Developer ID' not in result.stderr:
        raise SystemExit(f'Gatekeeper does not report {app.name} as notarized: {last_line(result)}')
