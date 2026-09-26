#!/usr/bin/env python3
"""Measure installed, paused Jot CPU use without changing capture state.

Keep the same window and focus throughout the measurement. Exit 1 means the
budget was exceeded; exit 2 means no valid idle measurement was available.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess
import time


HELPER = '/Applications/Jot.app/Contents/Helpers/jot'
EXECUTABLE = '/Applications/Jot.app/Contents/MacOS/Jot'


def status():
    return json.loads(subprocess.check_output([HELPER, 'status'], text=True))['result']


def idle(state):
    recovery = state.get('dictationRecovery', {})
    return (state['mode'] == 'paused' and not state['microphoneRunning']
            and not state['inferenceRunning'] and not state.get('speakerPassRunning')
            and state['models'] not in ('preparing', 'unloading')
            and not state.get('queuedAudioSeconds')
            and not recovery.get('cleanupPending') and not recovery.get('recoveryRunning')
            and not recovery.get('attemptPending'))


def cpu_time(pid):
    value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time='], text=True).strip()
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(value.split(':'))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--max-cpu', type=float, default=1.0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds < 1:
        parser.error('--seconds must be finite and at least 1')
    if not math.isfinite(args.max_cpu) or args.max_cpu < 0:
        parser.error('--max-cpu must be finite and nonnegative')
    before = status()
    if not idle(before):
        print('No baseline: Jot must be paused and idle. Capture was not changed.')
        return 2
    pid = before['resources']['processID']
    executable = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
    if executable != EXECUTABLE:
        print('No baseline: the running app is not /Applications/Jot.app.')
        return 2
    start = cpu_time(pid)
    began = time.monotonic()
    time.sleep(args.seconds)
    end = cpu_time(pid)
    elapsed = time.monotonic() - began
    after = status()
    if not idle(after) or after['resources']['processID'] != pid or end < start:
        print('Invalid measurement: state/process changed.')
        return 2
    cpu = 100 * (end - start) / elapsed
    result = dict(pid=pid, mode=after['mode'], models=after['models'],
                  elapsedSeconds=elapsed, cpuSeconds=end - start,
                  averageCPUPercent=cpu, threshold=args.max_cpu,
                  passed=cpu <= args.max_cpu, version=after['version'])
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (subprocess.CalledProcessError, KeyError, ValueError) as error:
        print(f'Invalid measurement: {error}')
        raise SystemExit(2)
