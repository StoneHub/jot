#!/usr/bin/env python3
"""Validate one jot-suggestion-eval output directory.

Checks structure and internal consistency only. It never assigns, infers or summarizes quality scores.
Exit status: 0 valid and complete, 1 invalid, 3 valid but the run stopped early or never finished.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / 'docs/evaluation/contextual-suggestions/scenarios.json'
RUN_FORMAT = 'jot.suggestion-evaluation-run'
RECORD_FORMAT = 'jot.suggestion-evaluation-record'
VERSION = 1
MODES = {'normal', 'oracle-context'}
GENERATORS = {'apple-fm', 'test-fake'}
OUTCOMES = {'suggest', 'abstain', 'invalidate', 'rejected', 'unavailable', 'error', 'timeout'}
PREVIEW_OUTCOMES = {'suggest', 'invalidate'}
CHANGE_KINDS = {'input-edited', 'source-deleted'}
SCORES = {'pass', 'fail', 'not-applicable'}
RUN_KEYS = {
    'format', 'version', 'runId', 'mode', 'generator', 'iterations', 'startedAt', 'finishedAt', 'completed',
    'stopReason', 'recordCount', 'corpus', 'sourceRevision', 'runtime', 'selection', 'generation', 'prompt', 'notice',
}
RECORD_KEYS = {
    'format', 'version', 'runId', 'iteration', 'mode', 'scenarioId', 'generator', 'run', 'selectedSources',
    'excludedSources', 'outcome', 'detail', 'rawOutput', 'outputText', 'change', 'timeToPreviewMs', 'generationMs',
    'durationMs', 'promptSHA256', 'selectionComparison', 'outcomeComparison', 'scores', 'scorer', 'notes',
}
SHA256 = re.compile(r'^[0-9a-f]{64}$')
EXIT_VALID, EXIT_INVALID, EXIT_INCOMPLETE = 0, 1, 3


def load(source):
    """Read JSON text or a file, rejecting duplicate object keys that json.loads would silently overwrite."""
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'duplicate JSON key {key!r}')
            result[key] = value
        return result
    text = source if isinstance(source, str) else source.read_text(encoding='utf-8')
    return json.loads(text, object_pairs_hook=unique_keys)


def is_text(value):
    return isinstance(value, str) and value.strip() != ''


def is_count(value, minimum=0):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def exact_keys(value, path, keys, fail):
    if not isinstance(value, dict):
        fail(path, 'expected an object')
        return False
    for key in sorted(keys - value.keys()):
        fail(path, f'missing {key!r}')
    for key in sorted(value.keys() - keys):
        fail(path, f'unknown key {key!r}')
    return True


def check_run(run, fail):
    if run.get('format') != RUN_FORMAT or run.get('version') != VERSION:
        fail('run.json', f'expected {RUN_FORMAT} version {VERSION}')
    if not is_text(run.get('runId')):
        fail('run.json.runId', 'must be non-empty text')
    if run.get('mode') not in MODES:
        fail('run.json.mode', f'must be one of {sorted(MODES)}')
    if run.get('generator') not in GENERATORS:
        fail('run.json.generator', f'must be one of {sorted(GENERATORS)}')
    if not is_count(run.get('iterations'), 1) or not is_count(run.get('recordCount')):
        fail('run.json', 'iterations must be >= 1 and recordCount >= 0')
    if not isinstance(run.get('completed'), bool):
        fail('run.json.completed', 'must be true or false')
    elif run['completed'] and (run.get('stopReason') is not None or not is_text(run.get('finishedAt'))):
        fail('run.json', 'a completed run has a finish time and no stop reason')
    corpus = run.get('corpus')
    if exact_keys(corpus, 'run.json.corpus', {'path', 'sha256', 'format', 'version', 'scenarioCount'}, fail):
        if not isinstance(corpus.get('sha256'), str) or not SHA256.match(corpus['sha256']):
            fail('run.json.corpus.sha256', 'must be a lowercase SHA-256')
        if not is_count(corpus.get('scenarioCount'), 1):
            fail('run.json.corpus.scenarioCount', 'must be >= 1')
    runtime = run.get('runtime')
    runtime_keys = {'operatingSystem', 'hardwareModel', 'modelAvailability', 'model', 'modelRevision', 'appleFMRevision'}
    if exact_keys(runtime, 'run.json.runtime', runtime_keys, fail) and runtime.get('modelRevision') is not None:
        fail('run.json.runtime.modelRevision', 'must stay null; Apple does not expose a model revision')


def check_record(record, path, run, scenario, fail):
    if not exact_keys(record, path, RECORD_KEYS, fail):
        return
    if record.get('format') != RECORD_FORMAT or record.get('version') != VERSION:
        fail(path, f'expected {RECORD_FORMAT} version {VERSION}')
    for key in ('runId', 'mode', 'generator'):
        if record.get(key) != run.get(key):
            fail(f'{path}.{key}', f'does not match run.json ({run.get(key)!r})')
    if not is_count(record.get('iteration'), 1) or record['iteration'] > run.get('iterations', 0):
        fail(f'{path}.iteration', 'must be between 1 and the run iterations')
    if not is_text(record.get('scenarioId')):
        fail(f'{path}.scenarioId', 'must be non-empty text')

    selected = record.get('selectedSources')
    selected_ids = []
    if not isinstance(selected, list):
        fail(f'{path}.selectedSources', 'expected a list')
    else:
        for item in selected:
            if exact_keys(item, f'{path}.selectedSources[]', {'id', 'revision'}, fail):
                if not is_text(item.get('id')) or not is_count(item.get('revision'), 1):
                    fail(f'{path}.selectedSources[]', 'needs an id and a revision >= 1')
                else:
                    selected_ids.append(item['id'])
    excluded = record.get('excludedSources')
    excluded_ids = []
    if not isinstance(excluded, list):
        fail(f'{path}.excludedSources', 'expected a list')
    else:
        for item in excluded:
            if exact_keys(item, f'{path}.excludedSources[]', {'id', 'reason'}, fail):
                if not is_text(item.get('id')) or not is_text(item.get('reason')):
                    fail(f'{path}.excludedSources[]', 'needs an id and a reason')
                else:
                    excluded_ids.append(item['id'])
    listed = selected_ids + excluded_ids
    if len(set(listed)) != len(listed):
        fail(path, 'a source is listed twice or as both selected and excluded')

    outcome, raw, text = record.get('outcome'), record.get('rawOutput'), record.get('outputText')
    run_label, prompt, generation = record.get('run'), record.get('promptSHA256'), record.get('generationMs')
    if outcome not in OUTCOMES:
        fail(f'{path}.outcome', f'must be one of {sorted(OUTCOMES)}')
    for key in ('detail', 'rawOutput', 'outputText', 'notes'):
        if record.get(key) is not None and not isinstance(record[key], str):
            fail(f'{path}.{key}', 'must be text or null')
    if run_label not in {'cold', 'warm', None}:
        fail(f'{path}.run', "must be 'cold', 'warm' or null")
    if prompt is not None and (not isinstance(prompt, str) or not SHA256.match(prompt)):
        fail(f'{path}.promptSHA256', 'must be a lowercase SHA-256 or null')
    if not is_count(record.get('durationMs')):
        fail(f'{path}.durationMs', 'must be an integer >= 0')
    for key in ('generationMs', 'timeToPreviewMs'):
        if record.get(key) is not None and not is_count(record[key]):
            fail(f'{path}.{key}', 'must be an integer >= 0 or null')
    if (prompt is None) != (generation is None):
        fail(path, 'promptSHA256 and generationMs are both set exactly when a request was made')
    if not selected_ids and (outcome != 'abstain' or prompt is not None or record.get('detail') != 'no-selected-source'):
        fail(path, 'with no selected source the record must abstain before inference (no-selected-source)')
    if prompt is None and (raw is not None or run_label is not None):
        fail(path, 'output or a cold/warm label without a request')
    if raw is not None and run_label is None:
        fail(f'{path}.run', 'a model response needs a cold or warm label')
    if outcome in PREVIEW_OUTCOMES:
        if not is_text(text) or not isinstance(raw, str) or record.get('timeToPreviewMs') is None:
            fail(path, f'{outcome} needs rawOutput, outputText and timeToPreviewMs')
    elif text is not None or record.get('timeToPreviewMs') is not None:
        fail(path, f'{outcome} has no outputText or timeToPreviewMs')
    if outcome == 'rejected' and (raw is None or not is_text(record.get('detail'))):
        fail(path, 'rejected keeps the raw response and names the reason')
    if outcome in {'unavailable', 'timeout', 'error'} and raw is not None:
        fail(path, f'{outcome} has no model response')
    if outcome == 'unavailable' and run_label is not None:
        fail(f'{path}.run', 'an unavailable model was never asked, so the record is neither cold nor warm')
    if outcome == 'timeout' and run_label is None:
        fail(f'{path}.run', 'a timed-out request is cold or warm')

    change = record.get('change')
    if change is not None:
        if exact_keys(change, f'{path}.change', {'kind', 'generatedPreviewWithdrawn', 'authoredPreviewWithdrawn'}, fail):
            if change.get('kind') not in CHANGE_KINDS:
                fail(f'{path}.change.kind', f'must be one of {sorted(CHANGE_KINDS)}')
            for key in ('generatedPreviewWithdrawn', 'authoredPreviewWithdrawn'):
                if change.get(key) not in {True, False, None}:
                    fail(f'{path}.change.{key}', 'must be true, false or null')
            withdrawn = change.get('generatedPreviewWithdrawn')
            if (outcome == 'invalidate') != (withdrawn is True) or (withdrawn is not None) != (outcome in PREVIEW_OUTCOMES):
                fail(f'{path}.change', 'invalidate means a generated preview was withdrawn; suggest means it was not')
    elif outcome == 'invalidate':
        fail(path, 'invalidate requires a change')

    comparison = record.get('selectionComparison')
    if run.get('mode') == 'oracle-context':
        if comparison is not None:
            fail(f'{path}.selectionComparison', 'must be null in oracle-context mode')
    elif exact_keys(comparison, f'{path}.selectionComparison',
                    {'matchesExpected', 'missingSources', 'unexpectedSources', 'reasonMismatches'}, fail):
        lists = [comparison.get(key) for key in ('missingSources', 'unexpectedSources', 'reasonMismatches')]
        if not all(isinstance(item, list) for item in lists):
            fail(f'{path}.selectionComparison', 'expected lists')
        elif comparison.get('matchesExpected') is not (not any(lists)):
            fail(f'{path}.selectionComparison.matchesExpected', 'must be true exactly when nothing differs')
    outcome_comparison = record.get('outcomeComparison')
    if exact_keys(outcome_comparison, f'{path}.outcomeComparison', {'expected', 'matches'}, fail):
        if outcome_comparison.get('matches') is not (outcome_comparison.get('expected') == outcome):
            fail(f'{path}.outcomeComparison.matches', 'must be true exactly when the outcome equals the expectation')

    scores, scorer = record.get('scores'), record.get('scorer')
    if not isinstance(scores, dict) or not scores:
        fail(f'{path}.scores', 'expected an object with one entry per applicable criterion')
    else:
        for key, value in scores.items():
            if value is not None and value not in SCORES:
                fail(f'{path}.scores.{key}', f'must be null or one of {sorted(SCORES)}')
        if any(value is not None for value in scores.values()) and not is_text(scorer):
            fail(f'{path}.scorer', 'a recorded score needs a named reviewer')
    if scorer is not None and not is_text(scorer):
        fail(f'{path}.scorer', 'must be a reviewer name or null')

    if scenario is not None:
        known = {source['id'] for source in scenario['sources']}
        if set(listed) != known:
            fail(path, 'selected and excluded sources must list every scenario source exactly once')
        if isinstance(scores, dict) and set(scores) != set(scenario['scoring']['criteria']):
            fail(f'{path}.scores', "keys must be the scenario's scoring criteria")
        if isinstance(outcome_comparison, dict) and outcome_comparison.get('expected') != scenario['expected']['outcome']:
            fail(f'{path}.outcomeComparison.expected', 'does not match the corpus')
        if (change is None) != ('change' not in scenario):
            fail(f'{path}.change', 'present exactly for scenarios with a change')


def validate(directory, corpus_path=None):
    """Return (errors, summary). An empty error list means the output is structurally valid."""
    errors = []

    def fail(path, message):
        errors.append(f'{path}: {message}')

    directory = Path(directory)
    try:
        run = load(directory / 'run.json')
    except (OSError, ValueError) as error:
        return [f'run.json: {error}'], {}
    if not exact_keys(run, 'run.json', RUN_KEYS, fail):
        return errors, {}
    check_run(run, fail)
    if errors:
        return errors, {}

    scenarios = None
    if corpus_path is not None:
        data = Path(corpus_path).read_bytes()
        if hashlib.sha256(data).hexdigest() != run['corpus'].get('sha256'):
            fail('run.json.corpus.sha256', f'does not match {corpus_path}')
        scenarios = {scenario['id']: scenario for scenario in load(data.decode('utf-8'))['scenarios']}

    try:
        lines = (directory / 'results.jsonl').read_text(encoding='utf-8').splitlines()
    except OSError as error:
        return errors + [f'results.jsonl: {error}'], {}
    records, seen, runs = [], set(), []
    for number, line in enumerate(lines, 1):
        path = f'results.jsonl:{number}'
        try:
            record = load(line)
        except ValueError as error:
            fail(path, f'invalid JSON ({error})')
            continue
        scenario = None
        if scenarios is not None and isinstance(record, dict):
            scenario = scenarios.get(record.get('scenarioId'))
            if scenario is None:
                fail(f'{path}.scenarioId', 'is not in the corpus')
        check_record(record, path, run, scenario, fail)
        if isinstance(record, dict):
            key = (record.get('iteration'), record.get('scenarioId'))
            if key in seen:
                fail(path, f'repeats iteration {key[0]} of {key[1]!r}')
            seen.add(key)
            if record.get('run') is not None:
                runs.append(record['run'])
            records.append(record)
    if runs and (runs[0] != 'cold' or runs.count('cold') != 1):
        fail('results.jsonl', 'exactly the first request of the run is cold')
    if len(records) != run.get('recordCount'):
        fail('run.json.recordCount', f'says {run.get("recordCount")} but results.jsonl has {len(records)} records')
    expected_count = run['iterations'] * run['corpus'].get('scenarioCount', 0)
    if run.get('completed') and len(records) != expected_count:
        fail('results.jsonl', f'a completed run has {expected_count} records, not {len(records)}')
    outcomes = {}
    for record in records:
        outcomes[record.get('outcome')] = outcomes.get(record.get('outcome'), 0) + 1
    return errors, {'mode': run['mode'], 'generator': run['generator'], 'records': len(records),
                    'completed': run['completed'], 'stopReason': run.get('stopReason'), 'outcomes': outcomes}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('directory', type=Path, help='an output directory written by jot-suggestion-eval')
    parser.add_argument('--corpus', type=Path, default=DEFAULT_CORPUS,
                        help='the corpus the run used (default: the committed corpus)')
    args = parser.parse_args(argv)
    errors, summary = validate(args.directory, args.corpus)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f'{len(errors)} problem(s) in {args.directory}.', file=sys.stderr)
        return EXIT_INVALID
    counts = ', '.join(f'{name} {count}' for name, count in sorted(summary['outcomes'].items()))
    label = ' Records are labeled test-fake, not model output.' if summary['generator'] == 'test-fake' else ''
    print(f"{summary['records']} {summary['mode']} records are structurally valid ({counts}).{label} "
          'This check assigns no quality scores.')
    if not summary['completed']:
        print(f"Run incomplete: {summary['stopReason'] or 'it never finished'}", file=sys.stderr)
        return EXIT_INCOMPLETE
    return EXIT_VALID


if __name__ == '__main__':
    sys.exit(main())
