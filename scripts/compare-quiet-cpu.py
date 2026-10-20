#!/usr/bin/env python3
"""Compare quiet-listening CPU between two Jot revisions on this Mac.

Builds JotRecoveryChecks in Release for each revision in its own worktree
under build/power/, runs `--quiet-cpu` on two synthetic `say` voices with a
fresh CFFIXED_USER_HOME, and prints the CPU summary lines side by side. Full
outputs, including saved rows to diff, stay in build/power/<label>.txt. It
never touches the installed app, the microphone or the running Jot. Remove
the worktrees afterwards with `rm -rf build/power && git worktree prune`.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

VOICES = [('Samantha', 'We should move the review to Thursday and ask Sam for the budget numbers before then.'),
          ('Daniel', 'Thursday works for me. I will send the numbers tonight and copy the whole team.')]
SUMMARY = re.compile(r'^QUIET CPU(?: SPEECH JOBS)?: ')


def run(command, cwd=None, env=None, output=None):
    print('+', ' '.join(str(part) for part in command), flush=True)
    return subprocess.run(command, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if output else None).stdout


def summary(text):
    """The per-workload CPU lines, without rows and words."""
    return [line for line in text.splitlines() if SUMMARY.match(line)]


def label(revision):
    return re.sub(r'[^A-Za-z0-9._-]+', '-', revision).strip('-')


def build_and_measure(root, revision, voices, out):
    sha = run(['git', 'rev-parse', '--verify', f'{revision}^{{commit}}'], cwd=root, output=True).strip()
    tree = out / f'tree-{sha[:12]}'
    if not tree.exists():
        run(['git', 'worktree', 'add', '--detach', str(tree), sha], cwd=root)
    derived = out / f'derived-{sha[:12]}'
    if shutil.which('xcodegen'):
        run(['xcodegen', 'generate'], cwd=tree)
    run(['xcodebuild', '-quiet', '-project', 'Jot.xcodeproj', '-scheme', 'JotRecoveryChecks', '-configuration', 'Release',
         '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(derived),
         '-clonedSourcePackagesDirPath', str(root / 'build/SourcePackages'), 'ENABLE_HARDENED_RUNTIME=NO', 'build'], cwd=tree)
    with tempfile.TemporaryDirectory(prefix='jot-quiet-cpu-home-') as home:
        env = dict(os.environ, CFFIXED_USER_HOME=home)
        text = run([str(derived / 'Build/Products/Release/JotRecoveryChecks'), '--quiet-cpu', *map(str, voices)],
                   cwd=tree, env=env, output=True)
    (out / f'{label(revision)}.txt').write_text(text)
    return sha, summary(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('base', help='baseline revision, such as origin/main or a commit')
    parser.add_argument('head', help='revision with the change')
    parser.add_argument('--repeats', type=int, default=1, help='run each revision this many times, alternating')
    args = parser.parse_args()
    root = Path(run(['git', 'rev-parse', '--show-toplevel'], output=True).strip())
    out = root / 'build/power'
    out.mkdir(parents=True, exist_ok=True)
    voices = []
    for index, (voice, sentence) in enumerate(VOICES):
        path = out / f'voice-{index}.aiff'
        if not path.exists():
            run(['say', '-v', voice, '-o', str(path), sentence])
        voices.append(path)
    results = []
    for _ in range(max(1, args.repeats)):
        for revision in (args.base, args.head):
            results.append((revision, *build_and_measure(root, revision, voices, out)))
    for revision, sha, lines in results:
        print(f'\n{revision} ({sha[:12]})')
        print('\n'.join(lines) or '  no QUIET CPU lines; see the full output in build/power/')
    print(f'\nFull outputs and rows: {out}')


if __name__ == '__main__':
    main()
