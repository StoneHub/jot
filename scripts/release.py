#!/usr/bin/env python3
"""Cut a Jot release from main: bump the version, build and sign, tag, and publish a GitHub release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from signing import local_signing_configuration, official_signing_configuration

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = root / 'build'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bump', help='patch, minor, major, or an explicit X.Y.Z')
parser.add_argument('--notes', help='Release notes; written to docs/RELEASE-NOTES-<version>.md and used for the tag and release')
parser.add_argument('--install', action='store_true', help='Install the released product into /Applications afterwards')
parser.add_argument('--local', action='store_true', help='Publish a pre-release signed with the local development identity, without notarization')
parser.add_argument('--dry-run', action='store_true', help='Bump, test, build, and zip, then restore the tree without committing, tagging, or publishing')
options = parser.parse_args()

def run(args, quiet=False, env=None):
    # Quiet commands show their output only when they fail.
    result = subprocess.run(args, text=True, capture_output=quiet, env=env)
    if result.returncode != 0:
        if quiet:
            print(result.stdout[-4000:], result.stderr[-4000:], sep='\n', file=sys.stderr)
        raise SystemExit(f'{" ".join(str(a) for a in args[:2])} failed with exit {result.returncode}.')
    return result
def out(args):
    return subprocess.check_output(args, text=True).strip()
def step(message):
    print(f'-> {message}', flush=True)

# a. Preconditions: releases come only from a clean, pushed main with a working signing identity.
if not options.notes:
    raise SystemExit('Pass --notes "text"; every release needs release notes.')
if out(['git', 'branch', '--show-current']) != 'main':
    raise SystemExit('Switch to main; releases are cut from main only.')
if out(['git', 'status', '--porcelain']):
    raise SystemExit('The working tree has changes; commit or stash them first.')
run(['git', 'fetch', 'origin', 'main', '--tags'], quiet=True)
if out(['git', 'rev-parse', 'HEAD']) != out(['git', 'rev-parse', 'origin/main']):
    raise SystemExit('HEAD differs from origin/main; pull or push first.')
if subprocess.run(['gh', 'auth', 'status'], capture_output=True).returncode != 0:
    raise SystemExit('gh is not logged in; run gh auth login.')
# A local release is signed with the development identity and skips notarization; it installs only on Macs that trust that certificate.
identity, team = local_signing_configuration() if options.local else official_signing_configuration()
notary_profile = os.environ.get('JOT_NOTARY_PROFILE')
if not options.local and not notary_profile:
    raise SystemExit('Set JOT_NOTARY_PROFILE to credentials saved with xcrun notarytool store-credentials, or pass --local.')
release_environment = os.environ.copy()
release_environment['JOT_SIGN_IDENTITY'] = identity
release_environment['JOT_SIGN_TEAM'] = team
step(f'Preconditions passed on main at {out(["git", "rev-parse", "--short", "HEAD"])}; signing as {identity}')

# b. Version bump. CFBundleVersion is the release count: existing v* tags + 1, so it always increases.
version_file = root / 'Sources/JotCore/JotVersion.swift'
project_file = root / 'project.yml'
plist_file = root / 'Resources/Info.plist'
current = re.search(r'current = "(\d+)\.(\d+)\.(\d+)"', version_file.read_text())
if not current:
    raise SystemExit('Cannot read JotVersion.current from Sources/JotCore/JotVersion.swift.')
major, minor, patch = (int(n) for n in current.groups())
if options.bump == 'patch':
    patch += 1
elif options.bump == 'minor':
    minor, patch = minor + 1, 0
elif options.bump == 'major':
    major, minor, patch = major + 1, 0, 0
elif re.fullmatch(r'\d+\.\d+\.\d+', options.bump):
    major, minor, patch = (int(n) for n in options.bump.split('.'))
else:
    raise SystemExit('bump must be patch, minor, major, or X.Y.Z')
version = f'{major}.{minor}.{patch}'
previous = '.'.join(current.groups())
if tuple(int(n) for n in version.split('.')) <= tuple(int(n) for n in previous.split('.')):
    raise SystemExit(f'{version} is not newer than the current {previous}.')
tag = f'v{version}'
if tag in out(['git', 'tag', '--list']).split():
    raise SystemExit(f'Tag {tag} already exists.')
build_number = len([t for t in out(['git', 'tag', '--list', 'v*']).split()]) + 1
notes_file = root / f'docs/RELEASE-NOTES-{version}.md'
if notes_file.exists():
    raise SystemExit(f'{notes_file.relative_to(root)} already exists.')
edits = {}
def rewrite(path, pattern, replacement, count=1):
    text = path.read_text()
    new, n = re.subn(pattern, replacement, text, count=count)
    if n != count:
        raise SystemExit(f'Expected {count} match(es) for {pattern!r} in {path.relative_to(root)}, found {n}.')
    edits.setdefault(path, text)
    path.write_text(new)
rewrite(version_file, r'current = "[^"]+"', f'current = "{version}"')
rewrite(project_file, r"CFBundleShortVersionString: '[^']+'", f"CFBundleShortVersionString: '{version}'")
rewrite(project_file, r"CFBundleVersion: '[^']+'", f"CFBundleVersion: '{build_number}'")
rewrite(plist_file, r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+', rf'\g<1>{version}')
rewrite(plist_file, r'(<key>CFBundleVersion</key>\s*<string>)[^<]+', rf'\g<1>{build_number}')
notes_file.write_text(f'# Jot {version}\n\n{options.notes.strip()}\n')
edits[notes_file] = None
step(f'Version {previous} -> {version} (build {build_number}); notes in {notes_file.relative_to(root)}')

def restore():
    for path, text in edits.items():
        if text is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(text)
    # xcodegen rewrites the project from project.yml; put it back too.
    run(['git', 'checkout', '--', 'Jot.xcodeproj/project.pbxproj'])

try:
    # c. Tests and a Release build of the exact product that ships.
    step('swift test')
    run(['swift', 'test'], quiet=True)
    step('build-install.py --configuration Release --build-only')
    run([sys.executable, str(root / 'scripts/build-install.py'), '--configuration', 'Release', '--build-only'], quiet=True,
        env=release_environment)
    proof = json.loads((work / 'release-proof.json').read_text())
    if proof.get('signingTeam') != team:
        raise SystemExit(f'Release proof reports signing team {proof.get("signingTeam")}, expected {team}.')
    app = Path(proof['source'])
    step(f'Built {app} (executable sha256 {proof["sha256"][:12]}…)')
    built = subprocess.check_output(['defaults', 'read', str(app / 'Contents/Info.plist'), 'CFBundleShortVersionString'], text=True).strip()
    if built != version:
        raise SystemExit(f'Built app reports version {built}, expected {version}.')

    # e. Package and notarize before tagging so a distribution failure leaves no tag behind.
    zip_path = work / f'Jot-{version}.zip'
    zip_path.unlink(missing_ok=True)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(zip_path)])
    if not options.dry_run and not options.local:
        submission = run(['xcrun', 'notarytool', 'submit', str(zip_path), '--keychain-profile', notary_profile,
                          '--wait', '--output-format', 'json'], quiet=True)
        notarization = json.loads(submission.stdout)
        if notarization.get('status') != 'Accepted':
            raise SystemExit(f'Apple notarization ended with {notarization.get("status", "unknown status")} '
                             f'(submission {notarization.get("id", "unknown")}).')
        step(f'Apple notarization accepted submission {notarization.get("id")}')
        run(['xcrun', 'stapler', 'staple', str(app)], quiet=True)
        run(['xcrun', 'stapler', 'validate', str(app)], quiet=True)
        run(['codesign', '--verify', '--deep', '--strict', str(app)], quiet=True)
        run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)], quiet=True)
        zip_path.unlink()
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(zip_path)])
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    checksum_path = work / f'Jot-{version}.zip.sha256'
    checksum_path.write_text(f'{digest}  {zip_path.name}\n')
    step(f'Zipped {zip_path.relative_to(root)} ({zip_path.stat().st_size} bytes, sha256 {digest})')

    changed = [str(p.relative_to(root)) for p in edits] + ['Jot.xcodeproj/project.pbxproj']
    if options.dry_run:
        step('Dry run: would commit ' + ', '.join(changed))
        step(f'Dry run: would {"tag" if options.local else "notarize, staple, tag"} {tag} and push main --follow-tags')
        step(f'Dry run: would run gh release create {tag} {zip_path.name} {checksum_path.name} --title "Jot {version}" --notes-file {notes_file.relative_to(root)}')
        restore()
        step('Dry run: tree restored')
        sys.exit(0)
except BaseException:
    restore()
    raise

# d. One commit and an annotated tag carrying the notes.
run(['git', 'add', '--'] + changed)
run(['git', 'commit', '-q', '-m', f'Release {version}'])
run(['git', 'tag', '-a', tag, '-F', str(notes_file)])
step(f'Committed "Release {version}" and tagged {tag}')

# f. Publish. The asset must be named Jot-<version>.zip; AppUpdater looks for exactly that name.
run(['git', 'push', 'origin', 'main', '--follow-tags'])
step('Pushed main and tag')
publish = ['gh', 'release', 'create', tag, str(zip_path), str(checksum_path), '--title', f'Jot {version}', '--notes-file', str(notes_file)]
if options.local:
    publish.append('--prerelease')
run(publish)
step(f'Release {tag} published: ' + out(['gh', 'release', 'view', tag, '--json', 'url', '--jq', '.url']))

# g. Optional install of the same product into /Applications.
if options.install:
    step('build-install.py --configuration Release (install)')
    run([sys.executable, str(root / 'scripts/build-install.py'), '--configuration', 'Release'],
        env=release_environment)
