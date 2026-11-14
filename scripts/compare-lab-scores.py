#!/usr/bin/env python3
"""Compare two `jot lab --set` score files and fail when the candidate regressed beyond the tolerances.

    python3 scripts/compare-lab-scores.py baseline/set-scores.json candidate/set-scores.json

Both files hold numbers only, so the table can go into a PR. Each item and variant is compared pair by pair: word
error rate raw and cleaned, deletions and insertions, speaker words right live and after the pass, and CPU seconds per
audio minute. The tolerances are absolute points for rates and a percentage for CPU.
"""
import argparse
import json
from pathlib import Path
import sys

TOLERANCES = dict(wer_rise=1.0, speaker_drop=2.0, cpu_rise=30.0)


def pairs(scores):
    return {(item['name'], variant['name']): variant for item in scores.get('items', []) for variant in item.get('variants', [])}


def points(value):
    return None if value is None else value * 100


def compare(baseline, candidate, tolerances=TOLERANCES):
    """Rows for the table and the failures, as sentences."""
    before, after = pairs(baseline), pairs(candidate)
    rows, failures = [], []
    for key in sorted(set(before) | set(after)):
        item, variant = key
        old, new = before.get(key), after.get(key)
        if new is None:
            failures.append(f'{item} / {variant}: in the baseline but not in the candidate')
            continue
        row = dict(item=item, variant=variant, new=True) if old is None else dict(item=item, variant=variant, new=False)
        for name, read in (('wer_raw', lambda v: points(rate(v['raw']))), ('wer_cleaned', lambda v: points(rate(v['cleaned']))),
                           ('deletions', lambda v: v['raw']['deletions']), ('insertions', lambda v: v['raw']['insertions']),
                           ('live', lambda v: points(v.get('liveSpeakerAccuracy'))), ('pass', lambda v: points(v.get('passSpeakerAccuracy'))),
                           ('cpu', lambda v: v.get('cpuSecondsPerAudioMinute'))):
            row[name] = (None if old is None else read(old), read(new))
        rows.append(row)
        if old is None:
            continue
        for name, label in (('wer_raw', 'WER raw'), ('wer_cleaned', 'WER cleaned')):
            a, b = row[name]
            if b - a > tolerances['wer_rise']:
                failures.append(f'{item} / {variant}: {label} rose {a:.1f}% → {b:.1f}% (tolerance {tolerances["wer_rise"]:.1f} points)')
        for name, label in (('live', 'live speakers'), ('pass', 'pass speakers')):
            a, b = row[name]
            if a is not None and b is not None and a - b > tolerances['speaker_drop']:
                failures.append(f'{item} / {variant}: {label} dropped {a:.1f}% → {b:.1f}% (tolerance {tolerances["speaker_drop"]:.1f} points)')
            elif a is not None and b is None:
                failures.append(f'{item} / {variant}: {label} were scored in the baseline but not in the candidate')
        a, b = row['cpu']
        if a and b is not None and (b - a) / a * 100 > tolerances['cpu_rise']:
            failures.append(f'{item} / {variant}: CPU per audio minute rose {a:.1f} → {b:.1f} s (tolerance {tolerances["cpu_rise"]:.0f}%)')
    return rows, failures


def rate(score):
    """`WordErrorRate.Score` stores the counts; the rate is derived, as in Swift."""
    words = score.get('referenceWords', 0)
    return 0 if not words else (score['substitutions'] + score['deletions'] + score['insertions']) / words


def cell(pair, unit='', digits=1):
    a, b = pair
    if b is None:
        return '–'
    fmt = f'{{:.{digits}f}}{unit}'
    if a is None:
        return fmt.format(b) + ' (new)'
    return f'{fmt.format(a)} → {fmt.format(b)}'


def table(rows):
    lines = ['| Item | Variant | WER raw | WER cleaned | Deleted | Inserted | Live speakers | Pass speakers | CPU s / audio min |',
             '| --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    for row in rows:
        lines.append(f'| {row["item"]} | {row["variant"]} | {cell(row["wer_raw"], "%")} | {cell(row["wer_cleaned"], "%")} | '
                     f'{cell(row["deletions"], digits=0)} | {cell(row["insertions"], digits=0)} | {cell(row["live"], "%")} | '
                     f'{cell(row["pass"], "%")} | {cell(row["cpu"])} |')
    return '\n'.join(lines)


def report(baseline, candidate, tolerances=TOLERANCES):
    rows, failures = compare(baseline, candidate, tolerances)
    text = table(rows)
    if failures:
        text += '\n\nRegressions beyond tolerance:\n' + '\n'.join(f'- {failure}' for failure in failures)
    else:
        text += '\n\nNo regression beyond tolerance.'
    return text, failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--max-wer-rise', type=float, default=TOLERANCES['wer_rise'], help='points of word error rate (default 1.0)')
    parser.add_argument('--max-speaker-drop', type=float, default=TOLERANCES['speaker_drop'], help='points of speaker words right (default 2.0)')
    parser.add_argument('--max-cpu-rise', type=float, default=TOLERANCES['cpu_rise'], help='percent of CPU seconds per audio minute (default 30)')
    args = parser.parse_args(argv)
    tolerances = dict(wer_rise=args.max_wer_rise, speaker_drop=args.max_speaker_drop, cpu_rise=args.max_cpu_rise)
    text, failures = report(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()), tolerances)
    print(text)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
