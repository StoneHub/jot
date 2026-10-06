#!/usr/bin/env python3
"""Build or verify a supplied Jot product, then install it without interrupting capture."""
import argparse
import sys
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
from signing import local_signing_configuration, verify_signing_team

root = Path(__file__).resolve().parents[1]
work = root / 'build'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def product_info(source):
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if (source.name != 'Jot.app' or info.get('CFBundleIdentifier') != 'space.jot.app'
            or info.get('CFBundleExecutable') != 'Jot'
            or not (source / 'Contents/MacOS/Jot').is_file()
            or not (source / 'Contents/Helpers/jot').is_file()):
        raise SystemExit('Expected a complete Jot.app product with its bundled CLI.')
    return info


def verify_product(source, configuration, team, expected=None):
    info = product_info(source)
    if expected:
        if (info.get('CFBundleShortVersionString') != expected['version']
                or info.get('CFBundleVersion') != expected['build']
                or digest(source / 'Contents/MacOS/Jot') != expected['sha256']):
            raise SystemExit('Product version, build number or executable SHA-256 differs from the release.')
    verify_signing_team(source, team)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    subprocess.run([sys.executable, str(root / 'scripts/check-no-feedback.py'), str(source)], check=True)
    if configuration == 'Release':
        entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(source)],
                                               stderr=subprocess.DEVNULL)
        if plistlib.loads(entitlements).get('com.apple.security.get-task-allow'):
            raise SystemExit('Release product unexpectedly allows debugger attachment.')
    return info


def build_product(configuration):
    # The Command Line Tools alone cannot build the app target.
    developer = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True)
    if developer.returncode != 0 or not Path(developer.stdout.strip(), 'usr/bin/xcodebuild').exists():
        raise SystemExit('Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app. '
                         'The Command Line Tools cannot build the Jot app target.')
    identity, team = local_signing_configuration()
    if shutil.which('xcodegen'):
        subprocess.run(['xcodegen', 'generate'], check=True)
    args = ['xcodebuild', '-project', 'Jot.xcodeproj', '-scheme', 'Jot',
            '-configuration', configuration, '-destination', 'platform=macOS,arch=arm64',
            '-derivedDataPath', 'build/DerivedData.noindex', '-clonedSourcePackagesDirPath', 'build/SourcePackages',
            'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}', f'DEVELOPMENT_TEAM={team}']
    print(f'Building; log: {work / "build.log"}', flush=True)
    with (work / 'build.log').open('w') as log:
        subprocess.run(args + ['build'], stdout=log, stderr=subprocess.STDOUT, check=True)
    settings = json.loads(subprocess.check_output(args + ['-showBuildSettings', '-json']))
    s = next(item['buildSettings'] for item in settings if item['target'] == 'Jot')
    source = Path(s['TARGET_BUILD_DIR']) / s['FULL_PRODUCT_NAME']
    verify_product(source, configuration, team)
    if configuration == 'Release':
        conditions = s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
        flags = s.get('OTHER_SWIFT_FLAGS', '')
        if 'DEBUG' in conditions or re.search(r'-D\s*DEBUG\b', flags):
            raise SystemExit('Release build unexpectedly defines DEBUG.')
        (work / 'release-proof.json').write_text(json.dumps(dict(source=str(source),
            configuration='Release', signingTeam=team, debugDefined=False, feedbackRuntimeMarkers=False,
            sha256=digest(source / 'Contents/MacOS/Jot')), indent=2) + '\n')
    return source, team


def stop_if_idle(destination):
    if not destination.exists():
        return
    helper = destination / 'Contents/Helpers/jot'
    expected = str(destination / 'Contents/MacOS/Jot')
    status = subprocess.run([str(helper), 'status'], capture_output=True, text=True)
    if status.returncode != 0:
        processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
        if expected in [line.strip() for line in processes]:
            raise SystemExit(f'Cannot establish idle state for {destination}; product not replaced.')
        return
    current = json.loads(status.stdout)['result']
    recovery = current.get('dictationRecovery', {})
    if (current['microphoneRunning'] or current['queuedAudioSeconds'] > 0
            or current.get('inferenceRunning') or current['models'] in ('preparing', 'unloading')
            or current.get('servicePhase') == 'pausing'
            or recovery.get('attemptPending') or recovery.get('recoveryRunning')
            or recovery.get('cleanupPending', 0) > 0
            or current.get('storageWorkPending', 0) > 0
            or current.get('speakerPassRunning') or current.get('speakerPassPending')):
        raise SystemExit('Product verified. Pause capture and wait for pending work before installing.')
    pid = current['resources']['processID']
    command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
    if command != expected:
        raise SystemExit(f'Refusing to stop a different runtime: {command}')
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(.1)
    raise SystemExit('Installed app did not stop. Product not replaced.')


def install_product(source, destination, configuration, team, expected=None):
    if destination.is_symlink() or source.resolve() == destination.resolve() or destination.resolve() in source.resolve().parents:
        raise SystemExit('Source must be separate from the installed app, and destination cannot be a symlink.')
    info = verify_product(source, configuration, team, expected)
    # Pin identity and hash for ordinary builds too, before stopping any runtime.
    expected = expected or dict(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                                sha256=digest(source / 'Contents/MacOS/Jot'))
    stop_if_idle(destination)
    verify_product(source, configuration, team, expected)
    # ditto merges directories, so copy into an empty path and retain a rollback bundle.
    backup = work / 'app-backups.noindex' / str(time.time_ns()) / destination.name
    had_previous = destination.exists()
    if had_previous:
        backup.parent.mkdir(parents=True)
        shutil.move(str(destination), str(backup))
    relative = Path('Contents/MacOS/Jot')
    try:
        subprocess.run(['ditto', str(source), str(destination)], check=True)
        verify_product(destination, configuration, team, expected)
    except BaseException:
        if destination.exists():
            shutil.rmtree(destination)
        if had_previous:
            shutil.move(str(backup), str(destination))
        raise
    helper = destination / 'Contents/Helpers/jot'
    link = Path.home() / '.local/bin/jot'
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.exists() and not link.is_symlink():
        link.symlink_to(helper)
    elif link.resolve() != helper.resolve():
        print(f'Existing {link} preserved. Use the bundled CLI directly.')
    subprocess.run(['open', str(destination)], check=True)
    for _ in range(50):
        status = subprocess.run([str(helper), 'status'], capture_output=True, text=True)
        if status.returncode == 0:
            current = json.loads(status.stdout)['result']
            command = subprocess.check_output(['ps', '-p', str(current['resources']['processID']), '-o', 'comm='], text=True).strip()
            if command != str(destination / relative):
                raise SystemExit(f'Installed service belongs to a different runtime: {command}; backup retained at {backup}')
            proof = dict(configuration=configuration, signingTeam=verify_signing_team(destination, team),
                         source=str(source), installed=str(destination), sha256=digest(destination / relative),
                         version=expected['version'], build=expected['build'], running=command,
                         pid=current['resources']['processID'])
            if proof['sha256'] != expected['sha256']:
                raise SystemExit(f'Installed executable changed after verification; backup retained at {backup}')
            (work / 'install-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
            print(json.dumps(proof, indent=2))
            if had_previous:
                shutil.rmtree(backup.parent, ignore_errors=True)
            return
        time.sleep(.2)
    raise SystemExit(f'Installed app launched but service did not become ready; backup retained at {backup}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    parser.add_argument('--build-only', action='store_true', help='Verify without replacing or launching the installed app')
    parser.add_argument('--product', type=Path, help='Use this packaged Release Jot.app without building or reading signing identities')
    for field in ('team', 'version', 'build', 'sha256'):
        parser.add_argument(f'--expected-{field}', help=f'Required with --product: released {field}')
    options = parser.parse_args(argv)
    expected_fields = [options.expected_team, options.expected_version, options.expected_build, options.expected_sha256]
    if options.product:
        if options.configuration != 'Release' or not all(expected_fields):
            parser.error('--product requires --configuration Release and all four --expected-* values')
        if not re.fullmatch(r'[0-9a-f]{64}', options.expected_sha256):
            parser.error('--expected-sha256 must be a lowercase SHA-256 digest')
    elif any(expected_fields):
        parser.error('--expected-* requires --product')
    product = options.product.resolve() if options.product else None
    os.chdir(root)
    work.mkdir(exist_ok=True)
    expected = None
    if options.product:
        source, team = product, options.expected_team
        expected = dict(version=options.expected_version, build=options.expected_build, sha256=options.expected_sha256)
        verify_product(source, options.configuration, team, expected)
    else:
        source, team = build_product(options.configuration)
    if options.build_only:
        print(json.dumps(dict(source=str(source), configuration=options.configuration, installed=False), indent=2))
        return
    install_product(source, Path('/Applications/Jot.app'), options.configuration, team, expected)


if __name__ == '__main__':
    main()
