#!/usr/bin/env python3
"""The accuracy gate (#222): score a lab set with this checkout's `jot-lab` and with a baseline commit's, and compare.

    python3 scripts/lab-accuracy-check.py --set ~/Documents/jot-lab/sets/synthetic --baseline-ref origin/main

The baseline's scores are cached per commit and set in `work/lab-baselines/`, so a baseline is built and run once.
Lab output folders go to the temporary directory (the lab refuses to write inside a git checkout) and only
`set-scores.json`, numbers, is kept. `local-pr-check` runs this for recognition, speaker and cleanup changes when
`JOT_LAB_SET` or `--lab-set` names a set.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
DERIVED = 'build/DerivedData.noindex'


def load_compare():
    spec = importlib.util.spec_from_file_location('compare_lab_scores', HERE / 'compare-lab-scores.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(*args, cwd):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def main_root(cwd):
    """The main checkout, also from inside one of its worktrees, so baselines and caches are shared."""
    common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=cwd))
    return common.parent if common.name == '.git' else Path(git('rev-parse', '--show-toplevel', cwd=cwd))


def set_fingerprint(folder):
    """The manifest and each file's size: a changed set means a new baseline run."""
    digest = hashlib.sha256((folder / 'set.json').read_bytes())
    manifest = json.loads((folder / 'set.json').read_text())
    for item in manifest.get('items', []):
        for key in ('audio', 'captions'):
            path = folder / item[key]
            digest.update(f'{item[key]}:{path.stat().st_size}'.encode())
    return digest.hexdigest()[:12]


def build_lab(tree, log):
    """Build the jot-lab helper and its frameworks in `tree`, as local-pr-check builds JotRecoveryChecks."""
    if shutil.which('xcodegen'):
        subprocess.run(['xcodegen', 'generate'], cwd=tree, check=True, stdout=subprocess.DEVNULL)
    command = ['xcodebuild', '-project', 'Jot.xcodeproj', '-scheme', 'JotLab', '-configuration', 'Debug',
               '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', DERIVED,
               '-clonedSourcePackagesDirPath', 'build/SourcePackages', 'build']
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as output:
        result = subprocess.run(command, cwd=tree, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise SystemExit(f'jot-lab did not build in {tree}; see {log}.')
    return tree / DERIVED / 'Build/Products/Debug/jot-lab'


def run_set(binary, set_folder, variants=None):
    """Run the set in a temporary folder outside any checkout and return the scores; the transcripts are deleted."""
    with tempfile.TemporaryDirectory(prefix='jot-lab-accuracy-') as scratch:
        out = Path(scratch) / 'run'
        command = [str(binary), '--set', str(set_folder), '--out', str(out)]
        if variants:
            command += ['--variants', str(variants)]
        result = subprocess.run(command)
        if result.returncode != 0:
            raise SystemExit(f'jot-lab exited {result.returncode} on {set_folder}.')
        return json.loads((out / 'set-scores.json').read_text())


def baseline_worktree(root, sha):
    tree = root / 'work' / 'lab-baseline'
    if tree.exists():
        if Path(git('rev-parse', '--show-toplevel', cwd=tree)).resolve() != tree.resolve():
            raise SystemExit(f'{tree} is not a git worktree; move it aside.')
        git('checkout', '--quiet', '--detach', sha, cwd=tree)
    else:
        tree.parent.mkdir(parents=True, exist_ok=True)
        git('worktree', 'prune', cwd=root)
        git('worktree', 'add', '--quiet', '--detach', str(tree), sha, cwd=root)
    return tree


def baseline_scores(root, sha, set_folder, fingerprint, variants, refresh=False):
    cache = root / 'work' / 'lab-baselines' / f'{sha}-{fingerprint}.json'
    if cache.exists() and not refresh:
        print(f'Baseline {sha[:7]}: cached scores in {cache}', flush=True)
        return json.loads(cache.read_text())
    print(f'Baseline {sha[:7]}: building jot-lab and scoring the set (cached afterwards)…', flush=True)
    tree = baseline_worktree(root, sha)
    binary = build_lab(tree, root / 'work' / 'lab-baselines' / f'{sha}-build.log')
    scores = run_set(binary, set_folder, variants)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(scores, indent=2, sort_keys=True) + '\n')
    return scores


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--set', type=Path, default=os.environ.get('JOT_LAB_SET'), help='the set folder (default $JOT_LAB_SET)')
    parser.add_argument('--baseline-ref', required=True, help='commit to compare against, such as origin/main or a merge base')
    parser.add_argument('--variants', type=Path, help='a variants file for both sides (default: the current settings only)')
    parser.add_argument('--candidate-binary', type=Path, help='an already built jot-lab for this checkout')
    parser.add_argument('--refresh-baseline', action='store_true', help='run the baseline again instead of using its cache')
    parser.add_argument('--out', type=Path, help='where to write accuracy-report.md and the candidate scores (default work/lab-accuracy/<head>)')
    parser.add_argument('--max-wer-rise', type=float, default=1.0)
    parser.add_argument('--max-speaker-drop', type=float, default=2.0)
    parser.add_argument('--max-cpu-rise', type=float, default=30.0)
    args = parser.parse_args(argv)
    if platform.system() != 'Darwin':
        raise SystemExit('The accuracy gate runs the real models; run it on the Mac.')
    if not args.set:
        raise SystemExit('Name the set: --set <folder> or JOT_LAB_SET. Make one with scripts/make-lab-set.py.')
    set_folder = Path(args.set).expanduser().resolve()
    if not (set_folder / 'set.json').is_file():
        raise SystemExit(f'{set_folder} has no set.json.')
    compare = load_compare()
    cwd = Path.cwd()
    tree = Path(git('rev-parse', '--show-toplevel', cwd=cwd))
    root = main_root(cwd)
    head = git('rev-parse', 'HEAD', cwd=tree)
    baseline = git('rev-parse', '--verify', f'{args.baseline_ref}^{{commit}}', cwd=tree)
    fingerprint = set_fingerprint(set_folder)
    out = args.out or root / 'work' / 'lab-accuracy' / head[:7]
    out.mkdir(parents=True, exist_ok=True)
    variants = args.variants.resolve() if args.variants else None
    before = baseline_scores(root, baseline, set_folder, fingerprint, variants, args.refresh_baseline)
    binary = args.candidate_binary or build_lab(tree, out / 'build.log')
    print(f'Candidate {head[:7]}: scoring the set…', flush=True)
    after = run_set(binary, set_folder, variants)
    (out / 'candidate-scores.json').write_text(json.dumps(after, indent=2, sort_keys=True) + '\n')
    tolerances = dict(wer_rise=args.max_wer_rise, speaker_drop=args.max_speaker_drop, cpu_rise=args.max_cpu_rise)
    text, failures = compare.report(before, after, tolerances)
    verdict = 'FAIL' if failures else 'PASS'
    report = (f'## Lab accuracy: {verdict}\n\nSet `{set_folder.name}` ({fingerprint}); baseline `{baseline[:7]}` → candidate `{head[:7]}`; '
              f'tolerances: WER +{tolerances["wer_rise"]:.1f} points, speakers −{tolerances["speaker_drop"]:.1f} points, CPU +{tolerances["cpu_rise"]:.0f}%.\n\n'
              + text + '\n')
    (out / 'accuracy-report.md').write_text(report)
    print(report)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
