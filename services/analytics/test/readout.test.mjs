// Run from this folder: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readout, measures } from "../readout.mjs";

test("Fix typos undo rate is undone presses over fixes, and dictation sums every hold", () => {
    const m = measures({ "typoFix.requested": 5, "typoFix.outcome.fixed": 3, "typoFix.outcome.insertionUnverified": 1,
        "typoFix.outcome.undone": 1, "dictation.completed": 9, "dictation.noSpeech": 1, "insertion.accessibility": 8, "insertion.unverified": 1 });
    assert.deepEqual([m.typoPresses, m.fixes, m.undone, m.holds, m.completed, m.deliveries, m.verified], [5, 4, 1, 10, 9, 9, 8]);
});

test("a readout sums Macs and counters per day and over the window", () => {
    const reports = [{ day: "2026-10-23", app: "0.3.5", os: "26.1", arch: "arm64", macs: 1 },
        { day: "2026-10-23", app: "0.3.4", os: "26.1", arch: "arm64", macs: 1 }];
    const usage = [{ day: "2026-10-23", name: "dictation.completed", count: 3 }, { day: "2026-10-23", name: "dictation.failed", count: 1 },
        { day: "2026-10-23", name: "typoFix.requested", count: 2 }, { day: "2026-10-23", name: "typoFix.outcome.fixed", count: 2 },
        { day: "2026-10-23", name: "dictationLatency.underOneSecond", count: 3 }, { day: "2026-10-23", name: "meeting.started", count: 1 },
        { day: "2026-10-23", name: "feature.typoFix", count: 2 }];
    const text = readout(reports, usage, 14).join("\n");
    assert.match(text, /2026-10-23 +2 +4 +75%/);
    assert.match(text, /4 holds, 75% completed\. completed 3, failed 1/);
    assert.match(text, /2 presses: 2 fixed, 0 undone \(0% of fixes\)/);
    assert.match(text, /0\.3\.5 on macOS 26\.1 arm64: 1/);
    assert.match(text, /Release to inserted text: underOneSecond 3/);
    assert.match(text, /Features on .*\n  typoFix 2/);
    assert.match(text, /Meetings\n  started 1\. Length: none/);
});

test("an empty database says when the first report arrives", () => {
    assert.match(readout([], [], 14).join("\n"), /No reports yet/);
});
