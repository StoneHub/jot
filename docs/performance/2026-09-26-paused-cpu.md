# Paused CPU investigation — September 26, 2026

## Finding and change

Paused resource samples published through `SpeechService.objectWillChange`, invalidating all service-observing SwiftUI views every five seconds. The sampled main-thread work included transcript and settings layout. The service also publishes once per second while listening, so the same unnecessary UI work occurred there.

Move the resource snapshot into an independently observed `ResourceReadout`. Only the sidebar meters, Activity metric grid, and menu resource text subscribe. The service retains a computed snapshot for CLI status/diagnostics. Sampling cadence and CPU accounting are unchanged.

The installed baseline was paused, microphone stopped, models unloaded, and no inference, cleanup, or speaker pass running. A ten-second process sample showed no idle suggestion monitor or speech inference. This change does not address the continuous-listening speech pipeline tracked in #93.

## Regression checks

Before the change, the real recovery-controller test failed with:

> Resource-only ticks told the whole window to redraw 2 times

After the change:

- Two seconds of synthetic silence and two empty recognition results cause zero whole-service invalidations.
- Six paused ticks still emit six resource readings and zero whole-service invalidations.
- CPU readouts still agree with independently read kernel CPU counters during synthetic inference.
- Complete recovery-controller checks pass, using a fresh `CFFIXED_USER_HOME`.
- `swift test`: 244 tests pass (23 JotChecks and 221 JotCoreTests).
- Python suite: 48 tests pass; 18 suggestion fixtures pass structural checks.
- Signed Release build passes signature, signing-team, no-DEBUG, and no-feedback checks.

## Installed measurements

Use `python3 scripts/check-paused-cpu.py --seconds 30 --output /tmp/jot-paused-cpu.json` with Jot already paused. Keep the same window and focus for the whole interval. The script measures the process's cumulative user + system CPU time using `ps time`, divided by monotonic wall time. It verifies installed process identity and paused/idle state at both endpoints. It does not pause or resume Jot.

These are short local measurements, not a hardware-independent performance guarantee. UI navigation, focus changes, window occlusion, and other machine activity can affect results. The reported sustained 3% was not reproduced during this run: pre-change averages ranged from 0.63% to 1.17%, with a transient UI reading of 2.7% after navigation.

| Paused scenario | Baseline average | Installed candidate average |
| --- | ---: | ---: |
| Live screen | 0.63% | 0.40% |
| Activity screen | 0.73% | 0.13% |
| TextEdit field focused, Jot Tuning in background | 1.17% | 0.07% |

Each average covers 30 seconds. All candidate measurements pass the 1% local budget. The baseline also had a Tuning-only reading of 0.67%; that scenario was not repeated separately.

Baseline and candidate are both locally signed Release builds, app version 0.2.6. The candidate also includes merged field-drafting changes missing from the older installed baseline; the regression test isolates the resource-publication change. The application remains paused after installation.

Raw profiles, test logs and readings are local under `work/paused-cpu/` (ignored), because process samples and app data may contain local context. No transcripts are included in this report.
