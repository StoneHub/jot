#!/usr/bin/env python3
"""Build, verify, and install the exact Xcode product. Never interrupts active capture."""
import hashlib
import json
import os
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
identity = os.environ.get('PORCH_SIGN_IDENTITY')
if not identity:
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    candidates = re.findall(r'"(Developer ID Application: [^"]+)"', identities)
    if not candidates:
        raise SystemExit('Set PORCH_SIGN_IDENTITY to an installed signing identity. Stable signing preserves macOS permissions.')
    identity = candidates[0]
team = os.environ.get('PORCH_SIGN_TEAM') or re.search(r'\(([A-Z0-9]+)\)$', identity).group(1)
if shutil.which('xcodegen'):
    subprocess.run(['xcodegen', 'generate'], check=True)
args = ['xcodebuild', '-project', 'PorchSpeech.xcodeproj', '-scheme', 'PorchSpeech',
        '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
        '-derivedDataPath', 'build/DerivedData', '-clonedSourcePackagesDirPath', 'build/SourcePackages',
        'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}', f'DEVELOPMENT_TEAM={team}']
print(f'Building; log: {work / "build.log"}', flush=True)
with (work / 'build.log').open('w') as log:
    subprocess.run(args + ['build'], stdout=log, stderr=subprocess.STDOUT, check=True)
settings = json.loads(subprocess.check_output(args + ['-showBuildSettings', '-json']))
s = next(item['buildSettings'] for item in settings if item['target'] == 'PorchSpeech')
source = Path(s['TARGET_BUILD_DIR']) / s['FULL_PRODUCT_NAME']
destination = Path('/Applications') / s['FULL_PRODUCT_NAME']
helper = destination / 'Contents/Helpers/porch'
# Only terminate the installed app when its own service says it is idle.
client = helper if helper.exists() else root / '.build/debug/porch'
if destination.exists() and client.exists():
    status = subprocess.run([str(client), 'status'], capture_output=True, text=True)
    if status.returncode == 0:
        current = json.loads(status.stdout)['result']
        if current['microphoneRunning'] or current['queuedAudioSeconds'] > 0 or current.get('inferenceRunning') or current['models'] == 'preparing':
            raise SystemExit('Build succeeded. Pause capture and wait for inference/model setup before installing.')
        pid = current['resources']['processID']
        command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
        if command != str(destination / 'Contents/MacOS' / s['EXECUTABLE_NAME']):
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
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
subprocess.run(['ditto', str(source), str(destination)], check=True)
relative = Path('Contents/MacOS') / s['EXECUTABLE_NAME']
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert digest(source / relative) == digest(destination / relative), 'Installed executable differs'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
assert (destination / 'Contents/Helpers/porch').exists()
link = Path.home() / '.local/bin/porch'
link.parent.mkdir(parents=True, exist_ok=True)
if not link.exists() and not link.is_symlink():
    link.symlink_to(destination / 'Contents/Helpers/porch')
elif link.resolve() != helper.resolve():
    print(f'Existing {link} preserved. Use the bundled CLI directly.')
subprocess.run(['open', str(destination)], check=True)
for _ in range(50):
    status = subprocess.run([str(helper), 'status'], capture_output=True, text=True)
    if status.returncode == 0:
        current = json.loads(status.stdout)['result']
        command = subprocess.check_output(['ps', '-p', str(current['resources']['processID']), '-o', 'comm='], text=True).strip()
        assert command == str(destination / relative), command
        proof = dict(source=str(source), installed=str(destination), sha256=digest(destination / relative), running=command, pid=current['resources']['processID'])
        (work / 'install-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps(proof, indent=2))
        break
    time.sleep(.2)
else:
    raise SystemExit('Installed app launched but service did not become ready; inspect its status window.')
