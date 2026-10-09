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
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse

MARKER = 'jot-local-check'
STATUS_CONTEXT = 'jot/local-macos-validation'
# Every posted check also reports its gate verdict here. Manual attestations are not merge gates, so this
# context never claims them; STATUS_CONTEXT stays the stricter, attested one.
GATE_STATUS_CONTEXT = 'jot/local-pr-check'
SWIFT_TRIGGERS = ('Sources/', 'Tests/', 'Package.swift', 'Package.resolved')
APP_TRIGGERS = ('Sources/', 'Resources/', 'project.yml', 'Jot.xcodeproj/', 'Package.swift', 'Package.resolved',
                'LICENSE', 'scripts/build-install.py', 'scripts/signing.py', 'scripts/check-no-feedback.py')
RECOVERY_TRIGGERS = ('Sources/Jot/', 'Sources/JotCore/', 'Sources/JotEngine/', 'scripts/check-recovery-flow.swift',
                     'scripts/check-capture-flow.swift', 'project.yml', 'Package.swift', 'Package.resolved')
NOT_COVERED = ('interactive UI, Accessibility and physical Fn behavior',
               'installed-app, updater and live capture behavior',
               'manual checks the PR description lists')
GATES = ('portable', 'swift-test', 'app-build', 'recovery-checks')
EXIT_CODES = {'PASS': 0, 'FAIL': 1, 'INCOMPLETE': 3}
SHA = re.compile(r'^[0-9a-f]{40}$')


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


def run_gate(gate, tree, logs, expected_head=None):
    log_path = logs / f'{gate.name}.log'
    gate.log = str(log_path)
    started = time.monotonic()
    with log_path.open('w') as log:
        for step in gate.steps:
            if expected_head:
                verify_tree(tree, expected_head)
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
            if expected_head:
                verify_tree(tree, expected_head)
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
    if not gates or statuses != {'passed'}:
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
    lines += [f'{where}: head `{short}`{branch}; base `{context["base"]}` at `{context.get("baseHead", "unknown")}`, '
              f'merge base `{context["mergeBase"][:7]}`.',
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
    if context.get('baseContained') is False:
        lines += ['', 'Head does not contain the current base. These are diagnostic head-only results; '
                  'native status publication requires an updated head and renewed validation.']
    if note:
        lines += ['', f'Reviewer note: {note}']
    for gate in gates:
        if gate.tail:
            lines += ['', f'<details><summary>{gate.name} log tail</summary>', '', '```', *gate.tail, '```', '', '</details>']
    return redact('\n'.join(lines)) + '\n'


def public_report(context, gates, result):
    """Only a fixed summary leaves the machine; logs, notes and attestation details stay local."""
    lines = [f'## Local check: {result}', '',
             f'<!-- {MARKER} verdict={result} head={context["head"]} pr={context["pr"]} -->', '',
             f'Head: `{context["head"]}`; base: `{context["baseHead"]}`.', '',
             '| Gate | Result |', '| --- | --- |']
    lines += [f'| {gate.title} | {gate.status} |' for gate in gates]
    if context.get('baseContained') is False:
        lines += ['', 'Head does not contain the current base: diagnostic head-only results, not native integration proof.']
    lines += ['', 'Manual checks are attestations, not automated UI-test results. '
              'Private logs and review notes remain local.']
    return '\n'.join(lines) + '\n'


def save_report(logs, context, gates, result, note=None):
    report = render(context, gates, result, note)
    (logs / 'report.md').write_text(report)
    (logs / 'report.json').write_text(json.dumps(dict(context, verdict=result, gates=[
        {'name': g.name, 'status': g.status, 'note': g.note, 'seconds': round(g.seconds, 1), 'log': redact(g.log),
         'steps': g.steps} for g in gates]), indent=2) + '\n')
    return report


def main_root(cwd):
    common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=cwd))
    return common.parent if common.name == '.git' else Path(git('rev-parse', '--show-toplevel', cwd=cwd))


def gh_pr(number, root):
    if not shutil.which('gh'):
        return None
    fields = 'number,title,url,headRefName,headRefOid,baseRefName,baseRefOid,isCrossRepository,state'
    try:
        result = subprocess.run(['gh', 'pr', 'view', str(number), '--json', fields],
                                cwd=root, capture_output=True, text=True)
        info = json.loads(result.stdout) if result.returncode == 0 else None
        return info if isinstance(info, dict) else None
    except (ValueError, OSError):
        return None


def require_postable_head(info, head):
    """A report may only be posted to an open PR whose current revision was tested."""
    if not info or info.get('state') != 'OPEN' or info.get('headRefOid') != head:
        raise SystemExit('Cannot post: the open PR head does not match the checked commit. Fetch and check it again.')


def require_pr_metadata(info, allow_fork=False):
    """Unknown fork provenance is not permission to execute code from a PR."""
    if not info or type(info.get('isCrossRepository')) is not bool:
        if allow_fork:
            return
        raise SystemExit('Cannot establish PR fork provenance. Restore gh access, or review the PR code and '
                         'explicitly use --allow-fork for a diagnostic run.')
    if info['isCrossRepository'] and not allow_fork:
        raise SystemExit('PR comes from another repository; review its code first, then use --allow-fork.')


def require_matching_pr(info, context):
    require_postable_head(info, context['head'])
    if (type(info.get('isCrossRepository')) is not bool
            or info.get('baseRefName') != context['base']
            or info.get('baseRefOid') != context['baseHead']
            or info.get('url') != context['url']):
        raise SystemExit('Cannot publish: PR base or repository metadata changed or is unavailable. Check it again.')


def fresh_base(root, remote, base):
    result = subprocess.run(['git', 'fetch', '--quiet', remote,
                             f'+refs/heads/{base}:refs/remotes/{remote}/{base}'],
                            cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit('INCOMPLETE: could not fetch the current base; a stale local copy is not validation.')
    return git('rev-parse', '--verify', f'refs/remotes/{remote}/{base}', cwd=root)


def verify_tree(tree, head):
    if git('rev-parse', 'HEAD', cwd=tree) != head or git('status', '--porcelain', cwd=tree):
        raise SystemExit('INCOMPLETE: the checked worktree is dirty or its HEAD changed. Commit and check again.')


def contains_base(root, base_head, head):
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', base_head, head],
                            cwd=root, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise SystemExit('INCOMPLETE: could not establish whether the checked head contains the current base.')
    return result.returncode == 0


def verify_revision(root, tree, context, remote, with_gh, require_integration=False):
    """Recheck the live base, PR head and worktree; never rely on cached refs for publication."""
    if fresh_base(root, remote, context['base']) != context['baseHead']:
        raise SystemExit('INCOMPLETE: the base moved while checks ran. Check the new revision again.')
    if context['pr']:
        ref = f'refs/remotes/{remote}/pr/{context["pr"]}'
        git('fetch', '--quiet', remote, f'+refs/pull/{context["pr"]}/head:{ref}', cwd=root)
        if git('rev-parse', ref, cwd=root) != context['head']:
            raise SystemExit('INCOMPLETE: the PR head moved while checks ran. Check the new revision again.')
        if with_gh:
            require_matching_pr(gh_pr(context['pr'], root), context)
    if require_integration and not contains_base(root, context['baseHead'], context['head']):
        raise SystemExit('INCOMPLETE: PR head does not contain the current base. Update the branch and check again.')
    verify_tree(tree, context['head'])


def manual_checks(files):
    """Conservative manual coverage: app behavior, plus actual model audio for pipeline changes."""
    checks = {'app-behavior'} if touches(files, APP_TRIGGERS) else set()
    # Names alone cannot identify all recognition paths (for example Transcriber or ListeningState).
    # Use the complete recovery footprint, including its build inputs, rather than infer semantics.
    if touches(files, RECOVERY_TRIGGERS):
        checks.add('real-model-audio')
    return checks


def read_attestation(path, context, required):
    if not required:
        return True
    try:
        data = json.loads(Path(path).read_text()) if path else None
        return (isinstance(data, dict) and data.get('head') == context['head']
                and data.get('baseHead') == context['baseHead']
                and isinstance(data.get('reviewer'), str) and bool(data['reviewer'].strip())
                and isinstance(data.get('checks'), dict)
                and all(isinstance(data['checks'].get(name), dict)
                        and data['checks'][name].get('result') == 'passed'
                        and isinstance(data['checks'][name].get('details'), str)
                        and bool(data['checks'][name]['details'].strip()) for name in required))
    except (OSError, ValueError, TypeError):
        return False


def native_verdict(gates, context, attestation):
    result = verdict(gates)
    if result == 'FAIL':
        return result
    if (platform.system() != 'Darwin' or context.get('baseContained') is not True
            or [gate.name for gate in gates] != list(GATES)
            or any(g.status != 'passed' for g in gates)
            or not read_attestation(attestation, context, manual_checks(context['files']))):
        return 'INCOMPLETE'
    return 'PASS'


def publish_status(root, context, state, status_context=STATUS_CONTEXT):
    """Use existing gh credentials only. Do not set up credentials or retry uncertain writes."""
    url = urlparse(context['url'])
    match = re.fullmatch(r'/([^/]+)/([^/]+)/pull/[0-9]+', url.path)
    if (url.scheme != 'https' or url.netloc != 'github.com' or not match
            or not SHA.fullmatch(context['head']) or not SHA.fullmatch(context['baseHead'])):
        raise SystemExit('Cannot publish: unverified GitHub PR URL or commit SHA.')
    repository = '/'.join(match.groups())
    if status_context == STATUS_CONTEXT:
        description = {'pending': 'Native validation running', 'success': 'All native gates and required attestations passed',
                       'failure': 'Native validation failed', 'error': 'Native validation incomplete'}[state]
    else:
        description = {'success': 'Mac gates passed; manual checks are the PR test list', 'failure': 'Mac gates failed',
                       'error': 'Mac gates incomplete'}[state]
    description += f'; base {context["baseHead"]}'
    try:
        result = subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{repository}/statuses/{context["head"]}',
                                 '-f', f'state={state}', '-f', f'context={status_context}',
                                 '-f', f'description={description}', '-f', f'target_url={context["url"]}'],
                                cwd=root, capture_output=True, text=True)
    except OSError:
        raise SystemExit('INCOMPLETE: could not run status publication; inspect GitHub before retrying.') from None
    if result.returncode != 0:
        raise SystemExit('INCOMPLETE: status publication failed or is uncertain; inspect GitHub before retrying.')


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
    parser.add_argument('--post', action='store_true', help='post the report as a PR comment and its verdict as the jot/local-pr-check status with gh')
    parser.add_argument('--publish-status', action='store_true',
                        help=f'run all gates on macOS and publish {STATUS_CONTEXT} with existing gh credentials')
    parser.add_argument('--ui-attestation', type=Path, help='local JSON recording SHA/base-bound manual checks')
    parser.add_argument('--note', help='reviewer note to include in the report')
    parser.add_argument('--no-gh', action='store_true', help='do not call gh for PR details')
    parser.add_argument('--allow-fork', action='store_true',
                        help='explicitly trust reviewed PR code when it is a fork or provenance is unavailable')
    args = parser.parse_args(argv)
    if not args.current and args.pr is None:
        parser.error('give a PR number, or --current')
    if args.post and (args.pr is None or args.no_gh or not shutil.which('gh')):
        parser.error('--post needs a PR number and gh')
    if args.post and args.dry_run:
        parser.error('--post cannot use --dry-run')
    if args.publish_status:
        if args.pr is None or args.current or args.no_gh or not shutil.which('gh'):
            parser.error('--publish-status needs a PR number and gh, and cannot use --current or --no-gh')
        if args.dry_run or args.skip:
            parser.error('--publish-status cannot use --dry-run or --skip')

    cwd = Path.cwd()
    root = main_root(cwd)
    info = None if args.no_gh or args.pr is None else gh_pr(args.pr, root)
    if args.pr is not None and not args.current and not args.dry_run:
        require_pr_metadata(info, args.allow_fork)
    base = args.base or (info or {}).get('baseRefName') or 'main'
    base_head = fresh_base(root, args.remote, base)

    if args.current:
        tree = Path(git('rev-parse', '--show-toplevel', cwd=cwd))
        head = git('rev-parse', 'HEAD', cwd=tree)
        dirty_current = bool(git('status', '--porcelain', cwd=tree))
        if dirty_current:
            if args.post:
                raise SystemExit('The checkout has uncommitted changes; a posted report must match a pushed commit.')
            print('Warning: uncommitted changes are tested but not named by the head commit.', file=sys.stderr)
        branch = git('branch', '--show-current', cwd=tree) or None
    else:
        dirty_current = False
        ref = f'refs/remotes/{args.remote}/pr/{args.pr}'
        git('fetch', '--quiet', args.remote, f'+refs/pull/{args.pr}/head:{ref}', cwd=root)
        head = git('rev-parse', ref, cwd=root)
        if info and info.get('headRefOid') != head:
            raise SystemExit('INCOMPLETE: gh metadata and fetched PR head disagree. Fetch and check again.')
        tree = None if args.dry_run else prepare_worktree(root, args.pr, head)
        branch = (info or {}).get('headRefName') or remote_branch(root, args.remote, head)

    merge_base = git('merge-base', base_head, head, cwd=root)
    files = [path for path in git('diff', '--name-only', merge_base, head, cwd=root).splitlines() if path]
    if args.current:
        files = sorted(set(files) | set(git('diff', '--name-only', 'HEAD', cwd=tree).splitlines())
                       | set(git('ls-files', '--others', '--exclude-standard', cwd=tree).splitlines()))
    head_files = set(git('ls-tree', '-r', '--name-only', head, cwd=root).splitlines())
    if args.current:
        head_files |= set(git('ls-files', '--others', '--exclude-standard', cwd=tree).splitlines())
    gates = plan(files, head_files, merge_base, head, args.filter, args.all or args.publish_status, set(args.skip))
    context = {'pr': args.pr, 'head': head, 'branch': branch, 'base': base, 'mergeBase': merge_base,
               'baseHead': base_head, 'baseContained': contains_base(root, base_head, head),
               'url': (info or {}).get('url'), 'files': files, 'machine': machine()}
    if info:
        require_matching_pr(info, context)
    if args.post or args.publish_status:
        require_matching_pr(info, context)
        verify_tree(tree, head)

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
    if args.publish_status:
        try:
            verify_revision(root, tree, context, args.remote, True, require_integration=args.publish_status)
            publish_status(root, context, 'pending')
        except (SystemExit, KeyboardInterrupt):
            save_report(logs, context, gates, 'INCOMPLETE', args.note)
            raise
    try:
        for gate in gates:
            if gate.status == 'planned':
                proof_head = None if dirty_current else head
                if proof_head:
                    verify_tree(tree, proof_head)
                run_gate(gate, tree, logs, expected_head=proof_head)
                if proof_head:
                    verify_tree(tree, proof_head)
        result = native_verdict(gates, context, args.ui_attestation) if args.publish_status else verdict(gates)
        # A dirty --current run is useful diagnostically, but is never proof of the named commit.
        if args.current and not (args.post or args.publish_status) and (dirty_current or git('status', '--porcelain', cwd=tree)):
            result = 'FAIL' if result == 'FAIL' else 'INCOMPLETE'
        else:
            verify_revision(root, tree, context, args.remote, bool(info) or args.post or args.publish_status,
                            require_integration=args.publish_status)
    except (SystemExit, KeyboardInterrupt):
        save_report(logs, context, gates, 'INCOMPLETE', args.note)
        if args.publish_status:
            publish_status(root, context, 'error')
        raise
    if args.publish_status:
        try:
            verify_revision(root, tree, context, args.remote, True, require_integration=args.publish_status)
        except (SystemExit, KeyboardInterrupt):
            save_report(logs, context, gates, 'INCOMPLETE', args.note)
            publish_status(root, context, 'error')
            raise
        # Attestations are local mutable files, so check their SHA-bound contents again at publication.
        result = native_verdict(gates, context, args.ui_attestation)
        try:
            publish_status(root, context, {'PASS': 'success', 'FAIL': 'failure', 'INCOMPLETE': 'error'}[result])
        except (SystemExit, KeyboardInterrupt):
            # Do not retry an uncertain API write or leave an old PASS report behind.
            save_report(logs, context, gates, 'INCOMPLETE', args.note)
            raise
        # GitHub status writes have no compare-and-swap for head/base. Revoke a success if a detected
        # publication-time race invalidates it; callers must also require an up-to-date base at merge.
        if result == 'PASS':
            try:
                verify_revision(root, tree, context, args.remote, True, require_integration=args.publish_status)
                if native_verdict(gates, context, args.ui_attestation) != 'PASS':
                    raise SystemExit('INCOMPLETE: the manual attestation changed during publication. Check again.')
            except (SystemExit, KeyboardInterrupt):
                save_report(logs, context, gates, 'INCOMPLETE', args.note)
                publish_status(root, context, 'error')
                raise
    report = save_report(logs, context, gates, result, args.note)
    if args.post:
        try:
            verify_revision(root, tree, context, args.remote, True, require_integration=args.publish_status)
        except (SystemExit, KeyboardInterrupt):
            save_report(logs, context, gates, 'INCOMPLETE', args.note)
            if args.publish_status:
                publish_status(root, context, 'error')
            raise
        if not args.publish_status:
            try:
                publish_status(root, context, {'PASS': 'success', 'FAIL': 'failure', 'INCOMPLETE': 'error'}[result],
                               GATE_STATUS_CONTEXT)
            except (SystemExit, KeyboardInterrupt):
                save_report(logs, context, gates, 'INCOMPLETE', args.note)
                raise
        summary = logs / 'public-report.md'
        summary.write_text(public_report(context, gates, result))
        subprocess.run(['gh', 'pr', 'comment', str(args.pr), '--body-file', str(summary)], cwd=root, check=True)
    print(report)
    if not args.current:
        print(f'The PR stays checked out in {redact(str(tree))}. To push a fix from there: '
              f'git push {args.remote} HEAD:{branch or "<head-branch>"}')
    return EXIT_CODES[result]


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('INCOMPLETE: validation cancelled.', file=sys.stderr)
        sys.exit(EXIT_CODES['INCOMPLETE'])
    except SystemExit as error:
        if isinstance(error.code, str):
            print(error.code, file=sys.stderr)
            sys.exit(EXIT_CODES['INCOMPLETE'])
        raise
