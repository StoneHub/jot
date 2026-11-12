#!/usr/bin/env python3
"""Run the real-app insertion matrix on this Mac and record a proof bound to the checked commit.

The matrix is `JotRecoveryChecks --insertion-matrix`: the app's own delivery code inserts one fixed phrase into
TextEdit, a Safari textarea, an Electron app and Terminal, and a Safari password field has to refuse it. This script
builds the tool, runs it, writes `build/insertion-matrix.json` with the commit it checked, and prints the table.
`release.py` refuses a release whose HEAD has no passing proof. See docs/INSERTION-MATRIX.md.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROWS = ('textedit', 'safari', 'password', 'terminal', 'electron')
PROOF = Path('build/insertion-matrix.json')
DERIVED = Path('build/DerivedData.noindex')
RUN_HINT = 'python3 scripts/insertion_matrix.py --electron <bundle id>'


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def build_tool(root, derived):
    """Build JotRecoveryChecks as local-pr-check does, and return the binary."""
    if shutil.which('xcodegen'):
        subprocess.run(['xcodegen', 'generate'], cwd=root, check=True, stdout=subprocess.DEVNULL)
    log = root / 'build' / 'insertion-matrix-build.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as output:
        result = subprocess.run(['xcodebuild', '-project', 'Jot.xcodeproj', '-scheme', 'JotRecoveryChecks',
                                 '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
                                 '-derivedDataPath', str(derived), '-clonedSourcePackagesDirPath', 'build/SourcePackages',
                                 'build'], cwd=root, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise SystemExit(f'JotRecoveryChecks did not build; see {log}.')
    return derived / 'Build/Products/Debug/JotRecoveryChecks'


def run_matrix(binary, report_path, electron=None, electron_new=None, skip=(), phrase=None):
    """Run the tool; its exit code is 1 when a row failed, and the report is written either way."""
    command = [str(binary), '--insertion-matrix', '--out', str(report_path)]
    if electron:
        command += ['--electron', electron]
        if electron_new:
            command += ['--electron-new', electron_new]
    for row in skip:
        command += ['--skip', row]
    if phrase:
        command += ['--phrase', phrase]
    return subprocess.run(command).returncode


def proof_document(report, head, dirty, machine=None, checked_at=None):
    """The proof release.py reads: the tool's report plus the commit it was run on."""
    return dict(head=head, dirty=dirty, checkedAt=checked_at or datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                machine=machine or f'macOS {platform.mac_ver()[0]} ({platform.machine()})',
                phrase=report.get('phrase'), rows=report.get('rows', []))


def proof_problems(path, head, rows=ROWS):
    """Why a proof does not cover `head`: empty when every required row passed on that exact commit."""
    try:
        proof = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return [f'no matrix report at {path}']
    except ValueError:
        return [f'{path} is not valid JSON']
    if not isinstance(proof, dict) or not isinstance(proof.get('rows'), list):
        return [f'{path} is not a matrix report']
    problems = []
    if proof.get('head') != head:
        problems.append(f'the report is for commit {str(proof.get("head") or "unknown")[:7]}, not {head[:7]}')
    if proof.get('dirty'):
        problems.append('the report was made on a tree with uncommitted changes')
    results = {row.get('target'): row for row in proof['rows'] if isinstance(row, dict)}
    for name in rows:
        row = results.get(name)
        if row is None:
            problems.append(f'row {name} is missing')
        elif row.get('result') != 'passed':
            detail = row.get('note') or row.get('outcome') or row.get('result') or 'unknown'
            problems.append(f'row {name} {row.get("result", "did not pass")}: {detail}')
    return problems


def table(rows):
    lines = ['| Row | Expected | Result | Path | Outcome | Role | Note |', '| --- | --- | --- | --- | --- | --- | --- |']
    for row in rows:
        role = '/'.join(part for part in (row.get('role'), row.get('subrole')) if part)
        lines.append(f'| {row.get("target")} | {row.get("expected")} | {row.get("result")} | {row.get("path") or "–"} | '
                     f'{row.get("outcome") or "–"} | {role or "–"} | {row.get("note") or ""} |')
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--electron', metavar='BUNDLE_ID', help='the Electron app for that row, such as com.microsoft.VSCode')
    parser.add_argument('--electron-new', metavar='KEY',
                        help='letter of the Command shortcut that opens a fresh field in that app (n for a new file), so no click is needed')
    parser.add_argument('--skip', action='append', default=[], choices=ROWS, help='leave a row out; the release check will then refuse this proof')
    parser.add_argument('--phrase', help='the one-line phrase to insert (default: the tool\'s fixed phrase)')
    parser.add_argument('--binary', type=Path, help='an already built JotRecoveryChecks, to skip the build')
    parser.add_argument('--out', type=Path, default=PROOF, help=f'where to write the proof (default {PROOF})')
    args = parser.parse_args(argv)
    if platform.system() != 'Darwin':
        raise SystemExit('The insertion matrix opens real Mac apps; run it on the Mac.')
    root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel'))
    head = git(root, 'rev-parse', 'HEAD')
    dirty = bool(git(root, 'status', '--porcelain'))
    if dirty:
        print('Warning: uncommitted changes; this proof will not count for a release.', file=sys.stderr)
    binary = args.binary or build_tool(root, root / DERIVED)
    if not os.access(binary, os.X_OK):
        raise SystemExit(f'{binary} is not an executable JotRecoveryChecks.')
    with tempfile.TemporaryDirectory(prefix='jot-insertion-matrix-') as scratch:
        report_path = Path(scratch) / 'report.json'
        code = run_matrix(binary, report_path, args.electron, args.electron_new, args.skip, args.phrase)
        if not report_path.exists():
            raise SystemExit(f'The matrix wrote no report (exit {code}); read its output above.')
        report = json.loads(report_path.read_text())
    out = args.out if args.out.is_absolute() else root / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(proof_document(report, head, dirty), indent=2, sort_keys=True) + '\n')
    print(table(report.get('rows', [])))
    problems = proof_problems(out, head)
    if problems:
        print('Not a release proof: ' + '; '.join(problems) + '.')
        return 1
    print(f'Insertion matrix passed on {head[:7]}; proof in {out.relative_to(root) if out.is_relative_to(root) else out}.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
