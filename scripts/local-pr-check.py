#!/usr/bin/env python3
"""Check out a Jot pull request in its own worktree, run the checks its diff needs, and report.

Run it from any checkout of this repository. It leaves the current checkout alone and never installs,
approves or merges anything.
"""
import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

MARKER = 'jot-local-check'
SWIFT_TRIGGERS = ('Sources/', 'Tests/', 'Package.swift', 'Package.resolved')
APP_TRIGGERS = ('Sources/', 'Resources/', 'project.yml', 'Jot.xcodeproj/', 'Package.swift', 'Package.resolved',
                'LICENSE', 'scripts/build-install.py', 'scripts/signing.py', 'scripts/check-no-feedback.py')
RECOVERY_TRIGGERS = ('Sources/Jot/', 'Sources/JotCore/', 'scripts/check-recovery-flow.swift',
                     'scripts/check-capture-flow.swift', 'project.yml', 'Package.swift', 'Package.resolved')
NOT_COVERED = ('interactive UI, Accessibility and physical Fn behavior',
               'installed-app, updater and live capture behavior',
               'manual checks the PR description lists')
GATES = ('portable', 'swift-test', 'app-build', 'recovery-checks')
EXIT_CODES = {'PASS': 0, 'FAIL': 1, 'INCOMPLETE': 3}


@dataclass
class Gate:
    name: str
    title: str
    steps: list
    needs: tuple = ()
    reason: str = ''
    status: str = 'planned'
    note: str = ''
    seconds: float = 0.0
    log: str = ''
    tail: list = field(default_factory=list)


def git(*args, cwd, check=True):
    result = subprocess.run(['git', *args], cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f'git {" ".join(args)} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def touches(files, triggers):
    return any(path == trigger or (trigger.endswith('/') and path.startswith(trigger))
               for path in files for trigger in triggers)


def plan(files, head_files, merge_base, head, filters=(), everything=False, skip=()):
    """Choose the gates this diff needs. `head_files` lists the checked-out tree, to find optional checks."""
    python = sys.executable or 'python3'
    portable = [['git', 'diff', '--check', merge_base, head]]
    if any(path.startswith('scripts/test_') and path.endswith('.py') for path in head_files):
        portable.append([python, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_*.py'])
    for script in ('check-no-feedback.py', 'check-suggestion-fixtures.py'):
        if f'scripts/{script}' in head_files:
            portable.append([python, f'scripts/{script}'])
    gates = [Gate('portable', 'Portable checks', portable, reason='always')]

    if everything or filters or touches(files, SWIFT_TRIGGERS):
        steps = [['swift', 'test', '--filter', name] for name in filters] + [['swift', 'test']]
        gates.append(Gate('swift-test', 'Swift package tests', steps, needs=('swift',),
                          reason='requested' if everything or filters else 'Swift sources, tests or manifest changed'))
    if everything or touches(files, APP_TRIGGERS):
        gates.append(Gate('app-build', 'Signed Debug app build (no install)',
                          [[python, 'scripts/build-install.py', '--build-only']], needs=('xcodebuild',),
                          reason='requested' if everything else 'app sources, resources or build configuration changed'))
    if everything or touches(files, RECOVERY_TRIGGERS):
        derived = 'build/DerivedData.noindex'
        steps = [['xcodegen', 'generate']] if shutil.which('xcodegen') else []
        steps += [['xcodebuild', '-project', 'Jot.xcodeproj', '-scheme', 'JotRecoveryChecks', '-configuration', 'Debug',
                   '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', derived,
                   '-clonedSourcePackagesDirPath', 'build/SourcePackages', 'build'],
                  [f'{derived}/Build/Products/Debug/JotRecoveryChecks']]
        gates.append(Gate('recovery-checks', 'JotRecoveryChecks (fresh CFFIXED_USER_HOME)', steps,
                          needs=('xcodebuild',),
                          reason='requested' if everything else 'service, store or recovery-check sources changed'))
    for gate in gates:
        if gate.name in skip:
            gate.status, gate.note = 'skipped', 'skipped by --skip'
        elif gate.needs and platform.system() != 'Darwin':
            gate.status, gate.note = 'unavailable', 'needs macOS with Xcode'
        elif any(shutil.which(tool) is None for tool in gate.needs):
            gate.status, gate.note = 'unavailable', f'missing {", ".join(t for t in gate.needs if not shutil.which(t))}'
    return gates


def redact(text):
    home = str(Path.home())
    return text.replace(home, '~') if home not in ('', '/') else text


def run_gate(gate, tree, logs):
    log_path = logs / f'{gate.name}.log'
    gate.log = str(log_path)
    started = time.monotonic()
    with log_path.open('w') as log:
        for step in gate.steps:
            env = dict(os.environ)
            if gate.name == 'recovery-checks' and step[0].endswith('JotRecoveryChecks'):
                env['CFFIXED_USER_HOME'] = tempfile.mkdtemp(prefix='jot-recovery-home-')
            log.write(f'$ {" ".join(step)}\n')
            log.flush()
            print(f'  {gate.name}: {" ".join(step)}', flush=True)
            try:
                code = subprocess.run(step, cwd=tree, stdout=log, stderr=subprocess.STDOUT, env=env).returncode
            except OSError as error:
                log.write(f'{error}\n')
                code = 127
            log.write(f'[exit {code}]\n\n')
            log.flush()
            if code != 0:
                gate.status, gate.note = 'failed', f'`{" ".join(step[:4])}` exited {code}'
                break
        else:
            gate.status = 'passed'
    gate.seconds = time.monotonic() - started
    if gate.status == 'failed':
        gate.tail = redact(log_path.read_text(errors='replace')).splitlines()[-40:]


def verdict(gates):
    statuses = {gate.status for gate in gates}
    if 'failed' in statuses:
        return 'FAIL'
    if statuses & {'unavailable', 'skipped', 'planned'}:
        return 'INCOMPLETE'
    return 'PASS'


def machine():
    def first_line(args):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=30)
            return (result.stdout or result.stderr).strip().splitlines()[0] if result.returncode == 0 else None
        except (OSError, IndexError, subprocess.TimeoutExpired):
            return None
    system = f'macOS {platform.mac_ver()[0]}' if platform.system() == 'Darwin' else platform.system()
    parts = [f'{system} ({platform.machine()})', f'Python {platform.python_version()}']
    for args in (['xcodebuild', '-version'], ['swift', '--version']):
        line = first_line(args) if shutil.which(args[0]) else None
        if line:
            parts.append(line)
    return ', '.join(parts)


def render(context, gates, result, note=None):
    head, short = context['head'], context['head'][:7]
    lines = [f'## Local check: {result}', '',
             f'<!-- {MARKER} verdict={result} head={head} pr={context.get("pr") or "none"} -->', '']
    where = f'PR #{context["pr"]}' if context.get('pr') else 'Current checkout'
    branch = f' on `{context["branch"]}`' if context.get('branch') else ''
    lines += [f'{where}: head `{short}`{branch}; base `{context["base"]}`, merge base `{context["mergeBase"][:7]}`.',
              f'Machine: {context["machine"]}.', '',
              '| Gate | Result | Time | Why it ran |', '| --- | --- | --- | --- |']
    for gate in gates:
        detail = f'{gate.status}' + (f': {gate.note}' if gate.note else '')
        seconds = f'{gate.seconds:.0f} s' if gate.status in ('passed', 'failed') else '-'
        lines.append(f'| {gate.title} | {detail} | {seconds} | {gate.reason} |')
    lines += ['', 'Commands:', '']
    for gate in gates:
        for step in gate.steps:
            lines.append(f'- {gate.name}: `{" ".join(step)}`')
    files = context['files']
    lines += ['', f'Changed files ({len(files)}): ' + (', '.join(f'`{path}`' for path in files[:40]) or 'none')
              + (' …' if len(files) > 40 else '')]
    lines += ['', 'Not covered by this script: ' + '; '.join(NOT_COVERED) + '.']
    if note:
        lines += ['', f'Reviewer note: {note}']
    for gate in gates:
        if gate.tail:
            lines += ['', f'<details><summary>{gate.name} log tail</summary>', '', '```', *gate.tail, '```', '', '</details>']
    return redact('\n'.join(lines)) + '\n'


def main_root(cwd):
    common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=cwd))
    return common.parent if common.name == '.git' else Path(git('rev-parse', '--show-toplevel', cwd=cwd))


def gh_pr(number, root):
    if not shutil.which('gh'):
        return None
    fields = 'number,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,state'
    result = subprocess.run(['gh', 'pr', 'view', str(number), '--json', fields], cwd=root, capture_output=True, text=True)
    try:
        return json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        return None


def remote_branch(root, remote, head):
    """Name the remote branch at `head`, for the push hint when gh is unavailable."""
    listing = subprocess.run(['git', 'ls-remote', '--heads', remote], cwd=root, capture_output=True, text=True)
    names = [line.split('refs/heads/', 1)[1] for line in listing.stdout.splitlines()
             if line.startswith(head) and 'refs/heads/' in line]
    return names[0] if len(names) == 1 else None


def prepare_worktree(root, number, head):
    tree = root / 'work' / f'pr-{number}'
    if tree.exists():
        # A plain directory here would make git act on the enclosing checkout instead.
        if Path(git('rev-parse', '--show-toplevel', cwd=tree)).resolve() != tree.resolve():
            raise SystemExit(f'{redact(str(tree))} is not a git worktree; move it aside and run again.')
        if git('status', '--porcelain', cwd=tree):
            raise SystemExit(f'{redact(str(tree))} has local changes. Push or discard them, then run again.')
        git('checkout', '--quiet', '--detach', head, cwd=tree)
    else:
        tree.parent.mkdir(parents=True, exist_ok=True)
        git('worktree', 'prune', cwd=root)
        git('worktree', 'add', '--quiet', '--detach', str(tree), head, cwd=root)
    return tree


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('pr', nargs='?', type=int, help='pull request number')
    parser.add_argument('--current', action='store_true', help='check the current checkout instead of a PR worktree')
    parser.add_argument('--base', help='base branch (default: the PR base, else main)')
    parser.add_argument('--remote', default='origin')
    parser.add_argument('--filter', action='append', default=[], metavar='TEST',
                        help='run `swift test --filter TEST` before the full suite; repeatable')
    parser.add_argument('--all', action='store_true', help='run every gate whatever the diff touches')
    parser.add_argument('--skip', action='append', default=[], choices=GATES, help='skip a gate (verdict INCOMPLETE)')
    parser.add_argument('--dry-run', action='store_true', help='print the plan without running it')
    parser.add_argument('--post', action='store_true', help='post the report as a PR comment with gh')
    parser.add_argument('--note', help='reviewer note to include in the report')
    parser.add_argument('--no-gh', action='store_true', help='do not call gh for PR details')
    parser.add_argument('--allow-fork', action='store_true', help='allow a PR from another repository')
    args = parser.parse_args(argv)
    if not args.current and args.pr is None:
        parser.error('give a PR number, or --current')
    if args.post and (args.pr is None or args.no_gh or not shutil.which('gh')):
        parser.error('--post needs a PR number and gh')

    cwd = Path.cwd()
    root = main_root(cwd)
    info = None if args.no_gh or args.pr is None else gh_pr(args.pr, root)
    if info and info.get('isCrossRepository') and not args.allow_fork:
        raise SystemExit(f'PR #{args.pr} comes from another repository; review it first, then use --allow-fork.')
    base = args.base or (info or {}).get('baseRefName') or 'main'
    fetched = subprocess.run(['git', 'fetch', '--quiet', args.remote, f'+refs/heads/{base}:refs/remotes/{args.remote}/{base}'],
                             cwd=root, capture_output=True, text=True)
    if fetched.returncode != 0:
        print(f'Warning: could not fetch {args.remote}/{base}; using the local copy. {fetched.stderr.strip()}',
              file=sys.stderr)
    git('rev-parse', '--verify', '--quiet', f'{args.remote}/{base}', cwd=root)

    if args.current:
        tree = Path(git('rev-parse', '--show-toplevel', cwd=cwd))
        head = git('rev-parse', 'HEAD', cwd=tree)
        if git('status', '--porcelain', cwd=tree):
            if args.post:
                raise SystemExit('The checkout has uncommitted changes; a posted report must match a pushed commit.')
            print('Warning: uncommitted changes are tested but not named by the head commit.', file=sys.stderr)
        branch = git('branch', '--show-current', cwd=tree) or None
    else:
        ref = f'refs/remotes/{args.remote}/pr/{args.pr}'
        git('fetch', '--quiet', args.remote, f'+refs/pull/{args.pr}/head:{ref}', cwd=root)
        head = git('rev-parse', ref, cwd=root)
        if info and info.get('headRefOid') and info['headRefOid'] != head:
            print(f'Warning: gh reports head {info["headRefOid"][:7]} but fetched {head[:7]}.', file=sys.stderr)
        tree = None if args.dry_run else prepare_worktree(root, args.pr, head)
        branch = (info or {}).get('headRefName') or remote_branch(root, args.remote, head)

    merge_base = git('merge-base', f'{args.remote}/{base}', head, cwd=root)
    files = [path for path in git('diff', '--name-only', merge_base, head, cwd=root).splitlines() if path]
    if args.current:
        files = sorted(set(files) | set(git('diff', '--name-only', 'HEAD', cwd=tree).splitlines()))
    head_files = set(git('ls-tree', '-r', '--name-only', head, cwd=root).splitlines())
    if args.current:
        head_files |= set(git('ls-files', '--others', '--exclude-standard', cwd=tree).splitlines())
    gates = plan(files, head_files, merge_base, head, args.filter, args.all, set(args.skip))
    context = {'pr': args.pr, 'head': head, 'branch': branch, 'base': base, 'mergeBase': merge_base,
               'files': files, 'machine': machine()}

    if args.dry_run:
        print(f'Would check {head[:7]} against {args.remote}/{base} ({len(files)} changed files):')
        for gate in gates:
            state = f' [{gate.status}: {gate.note}]' if gate.status != 'planned' else ''
            print(f'- {gate.name}: {gate.reason}{state}')
            for step in gate.steps:
                print(f'    {" ".join(step)}')
        return 0

    label = f'pr-{args.pr}-{head[:7]}' if args.pr is not None else f'current-{head[:7]}'
    logs = root / 'work' / 'pr-checks' / label
    logs.mkdir(parents=True, exist_ok=True)
    print(f'Checking {head[:7]} in {redact(str(tree))}; logs in {redact(str(logs))}', flush=True)
    for gate in gates:
        if gate.status == 'planned':
            run_gate(gate, tree, logs)
    result = verdict(gates)
    report = render(context, gates, result, args.note)
    (logs / 'report.md').write_text(report)
    (logs / 'report.json').write_text(json.dumps(dict(context, verdict=result, gates=[
        {'name': g.name, 'status': g.status, 'note': g.note, 'seconds': round(g.seconds, 1), 'log': redact(g.log),
         'steps': g.steps} for g in gates]), indent=2) + '\n')
    print(report)
    if args.post:
        subprocess.run(['gh', 'pr', 'comment', str(args.pr), '--body-file', str(logs / 'report.md')], cwd=root, check=True)
    if not args.current:
        print(f'The PR stays checked out in {redact(str(tree))}. To push a fix from there: '
              f'git push {args.remote} HEAD:{branch or "<head-branch>"}')
    return EXIT_CODES[result]


if __name__ == '__main__':
    sys.exit(main())
