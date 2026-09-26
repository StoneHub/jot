#!/usr/bin/env python3
"""Validate the synthetic contextual-suggestion scenarios.

Checks structure, identity and references only. A valid corpus says nothing about model quality.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / 'docs/evaluation/contextual-suggestions/scenarios.json'
FORMAT = 'jot.contextual-suggestion-scenarios'
SUPPORTED_VERSIONS = {1}

OUTCOMES = {'suggest', 'abstain', 'invalidate'}
INTEGRATIONS = {'native-ax', 'browser-ax', 'shell-bridge'}
MODES = {'reply', 'continuation', 'shell-command', 'draft'}
# text-entry is what the app reports for a multi-line field outside Codex.
PURPOSES = {'agent-prompt', 'chat-reply', 'shell-prompt', 'text-entry'}
ROLES_BY_KIND = {
    'dictation': {'user'},
    'meeting-transcript': {'user', 'participant'},
    'visible-message': {'user', 'participant', 'assistant'},
    'agent-prompt': {'user'},
    'assistant-response': {'assistant'},
    'summary': {'generated'},
    'pinned-selection': {'user', 'participant', 'assistant', 'generated'},
    'shown-suggestion': {'generated'},
}
STATUSES = {'current', 'stale', 'deleted'}
EXCLUSION_REASONS = {'unrelated-scope', 'stale', 'deleted', 'duplicate', 'generated-not-intent', 'not-relevant'}
CHANGE_KINDS = {'input-edited', 'source-deleted'}
SCOPE_KEYS = {'project', 'conversation', 'session'}
REQUIRED_COVERAGE = {
    'matching-context', 'unrelated-context', 'blank-field', 'unknown-preference', 'explicit-fix-intent',
    'role-confusion', 'multiple-speakers', 'stale-source', 'deleted-source', 'duplicate-event',
    'hostile-instruction', 'changed-input-revision',
}
COVERAGE = REQUIRED_COVERAGE | {'user-intent', 'generated-provenance'}
ID_PATTERN = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
TIMESTAMP_FORMAT = '%Y-%m-%dT%H:%M:%SZ'


def load(path):
    """Read JSON, rejecting duplicate object keys that json.load would silently overwrite."""
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'duplicate JSON key {key!r}')
            result[key] = value
        return result
    with open(path, encoding='utf-8') as file:
        return json.load(file, object_pairs_hook=unique_keys)


def is_text(value):
    return isinstance(value, str) and value.strip() != ''


def is_count(value, minimum):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def is_optional_text(value):
    return value is None or is_text(value)


def parse_time(value):
    try:
        return datetime.strptime(value, TIMESTAMP_FORMAT) if isinstance(value, str) else None
    except ValueError:
        return None


def has_keys(value, path, required, optional, fail):
    if not isinstance(value, dict):
        fail(path, 'expected an object')
        return False
    for key in sorted(required - value.keys()):
        fail(path, f'missing {key!r}')
    for key in sorted(value.keys() - required - optional):
        fail(path, f'unknown key {key!r}')
    return True


def id_list(value, path, known, fail, allow_empty=True):
    """Return the IDs in a list that must reference known IDs without repeats."""
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        fail(path, 'expected a list of IDs')
        return []
    if not value and not allow_empty:
        fail(path, 'must not be empty')
    if len(set(value)) != len(value):
        fail(path, 'repeats an ID')
    for item in value:
        if item not in known:
            fail(path, f'references unknown source {item!r}')
    return value


def check_target(target, path, fail):
    required = {'integration', 'app', 'mode', 'purpose', 'inputRevision', 'before', 'after', 'requestedAt'}
    if not has_keys(target, path, required, {'project', 'conversation', 'cwd', 'seed'}, fail):
        return None
    for key, allowed in (('integration', INTEGRATIONS), ('mode', MODES), ('purpose', PURPOSES)):
        if target.get(key) not in allowed:
            fail(f'{path}.{key}', f'must be one of {sorted(allowed)}')
    if not is_text(target.get('app')):
        fail(f'{path}.app', 'must be non-empty text')
    if not is_count(target.get('inputRevision'), 0):
        fail(f'{path}.inputRevision', 'must be an integer >= 0')
    for key in ('before', 'after'):
        if key in target and not isinstance(target[key], str):
            fail(f'{path}.{key}', 'must be text (empty for a blank field)')
    for key in ('project', 'conversation', 'cwd'):
        if not is_optional_text(target.get(key)):
            fail(f'{path}.{key}', 'must be non-empty text or null')
    # The seed is the user's notes that a draft replaces; before and after are the field text around them.
    if target.get('mode') == 'draft':
        if not is_text(target.get('seed')):
            fail(f'{path}.seed', 'draft mode needs the non-empty notes it rewrites')
    elif 'seed' in target:
        fail(f'{path}.seed', 'only draft mode has a seed')
    shell = target.get('integration') == 'shell-bridge'
    if shell != (target.get('mode') == 'shell-command') or shell != (target.get('purpose') == 'shell-prompt'):
        fail(path, 'shell-bridge, shell-command mode and shell-prompt purpose must be used together')
    if parse_time(target.get('requestedAt')) is None:
        fail(f'{path}.requestedAt', f'must match {TIMESTAMP_FORMAT}')
    return target


def check_sources(sources, path, requested_at, fail):
    """Return valid sources by ID after checking each source and its internal references."""
    if not isinstance(sources, list):
        fail(path, 'expected a list')
        return {}
    by_id = {}
    required = {'id', 'kind', 'role', 'origin', 'scope', 'timestamp', 'revision', 'status', 'text'}
    for index, source in enumerate(sources):
        source_path = f'{path}[{index}]'
        if not has_keys(source, source_path, required, {'speaker', 'derivedFrom', 'duplicateOf'}, fail):
            continue
        source_id = source.get('id')
        if not isinstance(source_id, str) or not ID_PATTERN.match(source_id):
            fail(f'{source_path}.id', 'must be lowercase words joined by hyphens')
            continue
        if source_id in by_id:
            fail(f'{source_path}.id', f'duplicate source id {source_id!r}')
            continue
        by_id[source_id] = source
        kind = source.get('kind')
        if kind not in ROLES_BY_KIND:
            fail(f'{source_path}.kind', f'must be one of {sorted(ROLES_BY_KIND)}')
        elif source.get('role') not in ROLES_BY_KIND[kind]:
            fail(f'{source_path}.role', f'{kind} role must be one of {sorted(ROLES_BY_KIND[kind])}')
        for key in ('origin', 'text'):
            if not is_text(source.get(key)):
                fail(f'{source_path}.{key}', 'must be non-empty text')
        if 'speaker' in source and not is_text(source['speaker']):
            fail(f'{source_path}.speaker', 'must be non-empty text')
        scope = source.get('scope')
        if has_keys(scope, f'{source_path}.scope', set(), SCOPE_KEYS, fail):
            for key, value in scope.items():
                if not is_optional_text(value):
                    fail(f'{source_path}.scope.{key}', 'must be non-empty text or null')
        timestamp = parse_time(source.get('timestamp'))
        if timestamp is None:
            fail(f'{source_path}.timestamp', f'must match {TIMESTAMP_FORMAT}')
        elif requested_at is not None and timestamp > requested_at:
            fail(f'{source_path}.timestamp', 'is after the request')
        if not is_count(source.get('revision'), 1):
            fail(f'{source_path}.revision', 'must be an integer >= 1')
        if source.get('status') not in STATUSES:
            fail(f'{source_path}.status', f'must be one of {sorted(STATUSES)}')
        if (kind == 'summary') != ('derivedFrom' in source):
            fail(source_path, 'summaries, and only summaries, must list derivedFrom')

    for index, source in enumerate(sources):
        if not isinstance(source, dict) or by_id.get(source.get('id')) is not source:
            continue
        source_path = f'{path}[{index}]'
        if 'derivedFrom' in source:
            derived, outdated = source['derivedFrom'], False
            if not isinstance(derived, list) or not derived:
                fail(f'{source_path}.derivedFrom', 'must be a non-empty list')
                derived = []
            for ref_index, ref in enumerate(derived):
                ref_path = f'{source_path}.derivedFrom[{ref_index}]'
                if not has_keys(ref, ref_path, {'id', 'revision'}, set(), fail):
                    continue
                parent = by_id.get(ref.get('id'))
                if parent is None or parent is source:
                    fail(ref_path, f'references unknown source {ref.get("id")!r}')
                elif not is_count(ref.get('revision'), 1) or not is_count(parent.get('revision'), 1):
                    fail(f'{ref_path}.revision', 'must be an integer >= 1')
                elif ref['revision'] > parent['revision']:
                    fail(f'{ref_path}.revision', 'is newer than the referenced source')
                else:
                    outdated = outdated or ref['revision'] < parent['revision'] or parent.get('status') == 'deleted'
            if outdated and source.get('status') == 'current':
                fail(f'{source_path}.status', 'derived from an older revision or deleted source, so it cannot be current')
        duplicate_of = source.get('duplicateOf')
        if duplicate_of is not None:
            original = by_id.get(duplicate_of)
            if original is None or original is source:
                fail(f'{source_path}.duplicateOf', f'references unknown source {duplicate_of!r}')
            elif 'duplicateOf' in original:
                fail(f'{source_path}.duplicateOf', 'must reference the retained source, not another duplicate')
    return by_id


def check_expected(expected, path, target, sources, fail):
    required = {'outcome', 'includedSources', 'excludedSources', 'reason'}
    if not has_keys(expected, path, required, {'idealText'}, fail):
        return None
    outcome = expected.get('outcome')
    if outcome not in OUTCOMES:
        fail(f'{path}.outcome', f'must be one of {sorted(OUTCOMES)}')
    if not is_text(expected.get('reason')):
        fail(f'{path}.reason', 'must be non-empty text')
    included = set(id_list(expected.get('includedSources'), f'{path}.includedSources', sources, fail))
    # A draft is grounded in the user's own notes, so it needs no source.
    if outcome == 'suggest' and not included and target.get('mode') != 'draft':
        fail(f'{path}.includedSources', 'a suggestion must be grounded in at least one included source')

    excluded = {}
    exclusions = expected.get('excludedSources')
    if not isinstance(exclusions, list):
        fail(f'{path}.excludedSources', 'expected a list')
        exclusions = []
    for index, item in enumerate(exclusions):
        item_path = f'{path}.excludedSources[{index}]'
        if not has_keys(item, item_path, {'id', 'reason'}, set(), fail):
            continue
        source_id, reason = item.get('id'), item.get('reason')
        if source_id not in sources:
            fail(item_path, f'references unknown source {source_id!r}')
        elif source_id in excluded:
            fail(item_path, f'repeats source {source_id!r}')
        elif source_id in included:
            fail(item_path, f'source {source_id!r} is both included and excluded')
        elif reason not in EXCLUSION_REASONS:
            fail(f'{item_path}.reason', f'must be one of {sorted(EXCLUSION_REASONS)}')
        else:
            excluded[source_id] = reason

    for source_id in sorted(set(sources) - included - set(excluded)):
        fail(path, f'source {source_id!r} has no expected selection; include or exclude it')
    for source_id in sorted(included & set(sources)):
        source = sources[source_id]
        if source.get('status') != 'current':
            fail(f'{path}.includedSources', f'{source_id!r} is included but its status is {source.get("status")!r}')
        if source.get('kind') == 'shown-suggestion':
            fail(f'{path}.includedSources', f'{source_id!r}: shown suggestions must be excluded as generated-not-intent')
        if 'duplicateOf' in source:
            fail(f'{path}.includedSources', f'{source_id!r} duplicates {source["duplicateOf"]!r}; include only the retained source')
        project = source.get('scope', {}).get('project') if isinstance(source.get('scope'), dict) else None
        if project and target.get('project') and project != target['project'] and source.get('kind') != 'pinned-selection':
            fail(f'{path}.includedSources', f'{source_id!r} belongs to project {project!r}, not the target project')
    for source_id, reason in sorted(excluded.items()):
        source = sources[source_id]
        consistent = {
            'stale': source.get('status') == 'stale',
            'deleted': source.get('status') == 'deleted',
            'duplicate': 'duplicateOf' in source,
            'generated-not-intent': source.get('kind') == 'shown-suggestion',
        }
        for required_reason, applies in consistent.items():
            if applies and reason != required_reason:
                fail(f'{path}.excludedSources', f'{source_id!r} must be excluded as {required_reason!r}')
            elif reason == required_reason and not applies:
                fail(f'{path}.excludedSources', f'{source_id!r} is excluded as {reason!r} but the source does not show that')
        if reason == 'unrelated-scope':
            scope = source.get('scope') if isinstance(source.get('scope'), dict) else {}
            if not scope.get('project') or scope.get('project') == target.get('project'):
                fail(f'{path}.excludedSources', f'{source_id!r} is unrelated-scope but shares or lacks the target project')

    ideal = expected.get('idealText')
    if ideal is not None:
        if outcome != 'suggest':
            fail(f'{path}.idealText', 'only a suggest outcome can have ideal text')
        check_authored(ideal, f'{path}.idealText', {'origin', 'text'}, fail)
    return {'outcome': outcome, 'included': included}


def check_authored(value, path, required, fail):
    if not has_keys(value, path, required, set(), fail):
        return False
    if value.get('origin') != 'authored':
        fail(f'{path}.origin', "origin must be 'authored'; this corpus contains no model output")
    if not is_text(value.get('text')):
        fail(f'{path}.text', 'must be non-empty text')
    return True


def check_invalidation(scenario, path, target, sources, expected, fail):
    pending, change = scenario.get('pendingSuggestion'), scenario.get('change')
    invalidates = expected is not None and expected['outcome'] == 'invalidate'
    if invalidates != (pending is not None and change is not None) or (pending is None) != (change is None):
        fail(path, 'invalidate requires pendingSuggestion and change, and they are only allowed with invalidate')
        return
    if pending is None:
        return
    pending_path = f'{path}.pendingSuggestion'
    pending_sources = []
    if check_authored(pending, pending_path, {'origin', 'text', 'inputRevision', 'sourceIds'}, fail):
        if pending.get('inputRevision') != target.get('inputRevision'):
            fail(f'{pending_path}.inputRevision', 'must equal the target inputRevision it was shown for')
        pending_sources = id_list(pending.get('sourceIds'), f'{pending_path}.sourceIds', sources, fail, allow_empty=False)
        for source_id in pending_sources:
            if source_id in sources and source_id not in expected['included']:
                fail(f'{pending_path}.sourceIds', f'{source_id!r} is not an included source')

    change_path = f'{path}.change'
    if not isinstance(change, dict) or change.get('kind') not in CHANGE_KINDS:
        fail(f'{change_path}.kind', f'must be one of {sorted(CHANGE_KINDS)}')
    elif change['kind'] == 'input-edited':
        if has_keys(change, change_path, {'kind', 'inputRevision', 'before', 'after'}, set(), fail):
            revision = change.get('inputRevision')
            if not is_count(revision, 0) or not is_count(target.get('inputRevision'), 0) or revision <= target['inputRevision']:
                fail(f'{change_path}.inputRevision', 'must be an integer greater than the target inputRevision')
            if not isinstance(change.get('before'), str) or not isinstance(change.get('after'), str):
                fail(change_path, 'before and after must be text')
            elif (change['before'], change['after']) == (target.get('before'), target.get('after')):
                fail(change_path, 'an input edit must change before or after')
    elif has_keys(change, change_path, {'kind', 'sourceIds'}, set(), fail):
        for source_id in id_list(change.get('sourceIds'), f'{change_path}.sourceIds', sources, fail, allow_empty=False):
            if source_id in sources and source_id not in pending_sources:
                fail(f'{change_path}.sourceIds', f'{source_id!r} was not a source of the pending suggestion')


def check_scoring(scoring, path, criteria, fail):
    if not has_keys(scoring, path, {'criteria', 'pass', 'failIf'}, set(), fail):
        return
    selected = scoring.get('criteria')
    if not isinstance(selected, list) or not selected or not all(isinstance(item, str) for item in selected):
        fail(f'{path}.criteria', 'expected a non-empty list of rubric IDs')
    else:
        if len(set(selected)) != len(selected):
            fail(f'{path}.criteria', 'repeats a criterion')
        for item in selected:
            if item not in criteria:
                fail(f'{path}.criteria', f'references unknown rubric criterion {item!r}')
        if 'outcome' not in selected:
            fail(f'{path}.criteria', "must include 'outcome'")
    if not is_text(scoring.get('pass')):
        fail(f'{path}.pass', 'must be non-empty text')
    fail_if = scoring.get('failIf')
    if not isinstance(fail_if, list) or not fail_if or not all(is_text(item) for item in fail_if):
        fail(f'{path}.failIf', 'expected a non-empty list of text')


def check_scenario(scenario, path, criteria, fail):
    required = {'id', 'title', 'covers', 'target', 'sources', 'expected', 'scoring'}
    if not has_keys(scenario, path, required, {'pendingSuggestion', 'change'}, fail):
        return None
    if not is_text(scenario.get('title')):
        fail(f'{path}.title', 'must be non-empty text')
    covers = scenario.get('covers')
    if not isinstance(covers, list) or not covers or not all(isinstance(item, str) for item in covers):
        fail(f'{path}.covers', 'expected a non-empty list of coverage tags')
        covers = []
    for tag in covers:
        if tag not in COVERAGE:
            fail(f'{path}.covers', f'unknown coverage tag {tag!r}')
    if len(set(covers)) != len(covers):
        fail(f'{path}.covers', 'repeats a tag')

    target = check_target(scenario.get('target'), f'{path}.target', fail) or {}
    sources = check_sources(scenario.get('sources'), f'{path}.sources', parse_time(target.get('requestedAt')), fail)
    expected = check_expected(scenario.get('expected'), f'{path}.expected', target, sources, fail)
    check_invalidation(scenario, path, target, sources, expected, fail)
    check_scoring(scenario.get('scoring'), f'{path}.scoring', criteria, fail)
    return {'covers': set(covers), 'outcome': expected['outcome'] if expected else None}


def validate(corpus):
    """Return structural errors as 'path: message' strings; an empty list means the corpus is valid."""
    errors = []

    def fail(path, message):
        errors.append(f'{path}: {message}')

    if not has_keys(corpus, '$', {'format', 'version', 'synthetic', 'notice', 'rubric', 'scenarios'}, set(), fail):
        return errors
    if corpus.get('format') != FORMAT:
        fail('$.format', f'must be {FORMAT!r}')
    version = corpus.get('version')
    if not is_count(version, 1) or version not in SUPPORTED_VERSIONS:
        fail('$.version', f'unsupported version {version!r}; supported: {sorted(SUPPORTED_VERSIONS)}')
    if corpus.get('synthetic') is not True:
        fail('$.synthetic', 'must be true; this corpus holds synthetic scenarios only')
    if not is_text(corpus.get('notice')):
        fail('$.notice', 'must be non-empty text')

    criteria = set()
    rubric = corpus.get('rubric')
    if not isinstance(rubric, list) or not rubric:
        fail('$.rubric', 'expected a non-empty list')
        rubric = []
    for index, criterion in enumerate(rubric):
        criterion_path = f'$.rubric[{index}]'
        if not has_keys(criterion, criterion_path, {'id', 'question'}, set(), fail):
            continue
        criterion_id = criterion.get('id')
        if not isinstance(criterion_id, str) or not ID_PATTERN.match(criterion_id):
            fail(f'{criterion_path}.id', 'must be lowercase words joined by hyphens')
        elif criterion_id in criteria:
            fail(f'{criterion_path}.id', f'duplicate rubric id {criterion_id!r}')
        else:
            criteria.add(criterion_id)
        if not is_text(criterion.get('question')):
            fail(f'{criterion_path}.question', 'must be non-empty text')

    scenarios = corpus.get('scenarios')
    if not isinstance(scenarios, list) or not scenarios:
        fail('$.scenarios', 'expected a non-empty list')
        return errors
    seen, covered, outcomes = set(), set(), set()
    for index, scenario in enumerate(scenarios):
        path = f'$.scenarios[{index}]'
        scenario_id = scenario.get('id') if isinstance(scenario, dict) else None
        if not isinstance(scenario_id, str) or not ID_PATTERN.match(scenario_id):
            fail(f'{path}.id', 'must be lowercase words joined by hyphens')
        elif scenario_id in seen:
            fail(f'{path}.id', f'duplicate scenario id {scenario_id!r}')
        else:
            seen.add(scenario_id)
            path = f'{path}({scenario_id})'
        result = check_scenario(scenario, path, criteria, fail)
        if result:
            covered |= result['covers']
            outcomes.add(result['outcome'])
    missing = REQUIRED_COVERAGE - covered
    if missing:
        fail('$.scenarios', f'missing required coverage: {sorted(missing)}')
    for outcome in sorted(OUTCOMES - outcomes):
        fail('$.scenarios', f'needs at least one {outcome!r} scenario')
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('corpus', nargs='?', type=Path, default=DEFAULT_CORPUS, help='defaults to the committed corpus')
    args = parser.parse_args(argv)
    try:
        corpus = load(args.corpus)
    except (OSError, ValueError) as error:
        print(f'{args.corpus}: cannot load: {error}', file=sys.stderr)
        return 1
    errors = validate(corpus)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f'{len(errors)} structural error(s) in {args.corpus}', file=sys.stderr)
        return 1
    print(f'{len(corpus["scenarios"])} synthetic scenarios are structurally valid. '
          'This does not measure suggestion quality.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
