#!/usr/bin/env python3
"""Build, verify, and install the exact Xcode product. Never interrupts active capture."""
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

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = root / 'build'
work.mkdir(exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
parser.add_argument('--build-only', action='store_true', help='Verify the build without replacing or launching the installed app')
options = parser.parse_args()
# xcodebuild ships with Xcode; the Command Line Tools alone cannot build the app target.
developer = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True)
if developer.returncode != 0 or not Path(developer.stdout.strip(), 'usr/bin/xcodebuild').exists():
    raise SystemExit('Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app. '
                     'The Command Line Tools cannot build the Jot app target.')
identity = os.environ.get('JOT_SIGN_IDENTITY')
if not identity:
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    candidates = re.findall(r'"(Developer ID Application: [^"]+)"', identities)
    if not candidates:
        raise SystemExit('Set JOT_SIGN_IDENTITY to an installed signing identity. Stable signing preserves macOS permissions.')
    identity = candidates[0]
team = os.environ.get('JOT_SIGN_TEAM')
if not team:
    # Identity names normally end in the team ID, as in "Developer ID Application: Name (TEAMID)".
    match = re.search(r'\(([A-Z0-9]+)\)$', identity)
    if not match:
        raise SystemExit(f'Cannot read a team ID from JOT_SIGN_IDENTITY ({identity}). Set JOT_SIGN_TEAM as well.')
    team = match.group(1)
if shutil.which('xcodegen'):
    subprocess.run(['xcodegen', 'generate'], check=True)
args = ['xcodebuild', '-project', 'Jot.xcodeproj', '-scheme', 'Jot',
        '-configuration', options.configuration, '-destination', 'platform=macOS,arch=arm64',
        '-derivedDataPath', 'build/DerivedData', '-clonedSourcePackagesDirPath', 'build/SourcePackages',
        'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}', f'DEVELOPMENT_TEAM={team}']
print(f'Building; log: {work / "build.log"}', flush=True)
with (work / 'build.log').open('w') as log:
    subprocess.run(args + ['build'], stdout=log, stderr=subprocess.STDOUT, check=True)
settings = json.loads(subprocess.check_output(args + ['-showBuildSettings', '-json']))
s = next(item['buildSettings'] for item in settings if item['target'] == 'Jot')
source = Path(s['TARGET_BUILD_DIR']) / s['FULL_PRODUCT_NAME']
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
subprocess.run([sys.executable, str(root / 'scripts/check-no-feedback.py'), str(source)], check=True)
if options.configuration == 'Release':
    entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(source)], stderr=subprocess.DEVNULL)
    if plistlib.loads(entitlements).get('com.apple.security.get-task-allow'):
        raise SystemExit('Release build unexpectedly allows debugger attachment.')
    conditions = s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
    flags = s.get('OTHER_SWIFT_FLAGS', '')
    if 'DEBUG' in conditions or re.search(r'-D\s*DEBUG\b', flags):
        raise SystemExit('Release build unexpectedly defines DEBUG.')
    (work / 'release-proof.json').write_text(json.dumps(dict(source=str(source),
        configuration='Release', debugDefined=False, feedbackRuntimeMarkers=False,
        sha256=hashlib.sha256((source / 'Contents/MacOS' / s['EXECUTABLE_NAME']).read_bytes()).hexdigest()), indent=2) + '\n')
if options.build_only:
    print(json.dumps(dict(source=str(source), configuration=options.configuration, installed=False), indent=2))
    sys.exit(0)
destination = Path('/Applications') / s['FULL_PRODUCT_NAME']
helper = destination / 'Contents/Helpers/jot'
# Upgrade the previous product only while both services are idle.
legacy = Path('/Applications/Porch Speech.app')
support = Path.home() / 'Library/Application Support'
old_data, new_data = support / 'PorchSpeech', support / 'Jot'
if legacy.exists() and old_data.exists() and new_data.exists():
    raise SystemExit('Both legacy and Jot data exist; refusing to merge or overwrite history.')
for app, cli, executable in [(destination, helper, s['EXECUTABLE_NAME']),
                             (legacy, legacy / 'Contents/Helpers/porch', 'Porch Speech')]:
    if not app.exists():
        continue
    status = subprocess.run([str(cli), 'status'], capture_output=True, text=True)
    expected = str(app / 'Contents/MacOS' / executable)
    if status.returncode != 0:
        processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
        if expected in [line.strip() for line in processes]:
            raise SystemExit(f'Cannot establish idle state for {app}; product not replaced.')
        continue
    current = json.loads(status.stdout)['result']
    if current['microphoneRunning'] or current['queuedAudioSeconds'] > 0 or current.get('inferenceRunning') or current['models'] == 'preparing':
        raise SystemExit('Build succeeded. Pause capture and wait for inference/model setup before installing.')
    pid = current['resources']['processID']
    command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
    if command != expected:
        raise SystemExit(f'Refusing to stop a different runtime: {command}')
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(.1)
    else:
        raise SystemExit('Installed app did not stop. Product not replaced.')
if old_data.exists() and not new_data.exists():
    old_data.rename(new_data)
# Import preferences once before the new bundle starts; preserve the old domain.
old_preferences = subprocess.run(['defaults', 'export', 'space.porchspeech.app', '-'], capture_output=True)
new_preferences = subprocess.run(['defaults', 'export', 'space.jot.app', '-'], capture_output=True)
if old_preferences.returncode == 0:
    previous = plistlib.loads(old_preferences.stdout)
    preferences = plistlib.loads(new_preferences.stdout) if new_preferences.returncode == 0 else {}
    if not preferences.get('jotLegacyPreferencesMigrated'):
        for key in ['fnRequested', 'historyTextView', 'modelUpdateChecks', 'modelsPrepared', 'servicePaused', 'transcriptionTuning']:
            if key in previous and key not in preferences:
                preferences[key] = previous[key]
        preferences['jotLegacyPreferencesMigrated'] = True
        subprocess.run(['defaults', 'import', 'space.jot.app', '-'], input=plistlib.dumps(preferences), check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
# ditto merges existing directories: Debug-only dylibs would invalidate a Release seal.
# The runtime is already idle/stopped. Preserve its bundle and install into an empty path.
backup = work / 'app-backups' / str(time.time_ns()) / destination.name
had_previous = destination.exists()
if had_previous:
    backup.parent.mkdir(parents=True)
    shutil.move(str(destination), str(backup))
relative = Path('Contents/MacOS') / s['EXECUTABLE_NAME']
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
try:
    subprocess.run(['ditto', str(source), str(destination)], check=True)
    assert digest(source / relative) == digest(destination / relative), 'Installed executable differs'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    subprocess.run([sys.executable, str(root / 'scripts/check-no-feedback.py'), str(destination)], check=True)
    assert (destination / 'Contents/Helpers/jot').exists()
except BaseException:
    if destination.exists():
        shutil.rmtree(destination)
    if had_previous:
        shutil.move(str(backup), str(destination))
    raise
if had_previous:
    print(f'Previous app preserved: {backup}', flush=True)
link = Path.home() / '.local/bin/jot'
link.parent.mkdir(parents=True, exist_ok=True)
if not link.exists() and not link.is_symlink():
    link.symlink_to(destination / 'Contents/Helpers/jot')
elif link.resolve() != helper.resolve():
    print(f'Existing {link} preserved. Use the bundled CLI directly.')
subprocess.run(['open', str(destination)], check=True)
for _ in range(50):
    status = subprocess.run([str(helper), 'status'], capture_output=True, text=True)
    if status.returncode == 0:
        current = json.loads(status.stdout)['result']
        command = subprocess.check_output(['ps', '-p', str(current['resources']['processID']), '-o', 'comm='], text=True).strip()
        assert command == str(destination / relative), command
        proof = dict(configuration=options.configuration, source=str(source), installed=str(destination), sha256=digest(destination / relative), running=command, pid=current['resources']['processID'])
        (work / 'install-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps(proof, indent=2))
        break
    time.sleep(.2)
else:
    raise SystemExit('Installed app launched but service did not become ready; inspect its status window.')

# Retire the old app reversibly after Jot has passed installation and launch checks.
if legacy.exists():
    archive = work / 'legacy-app-backup'
    archive.mkdir(exist_ok=True)
    saved = archive / legacy.name
    if saved.exists():
        raise SystemExit(f'Jot is installed; existing backup at {saved} prevents retiring the old app.')
    shutil.move(str(legacy), str(saved))
old_link = Path.home() / '.local/bin/porch'
if old_link.is_symlink() and os.readlink(old_link) == str(legacy / 'Contents/Helpers/porch'):
    old_link.unlink()
