// Prints what Jot's analytics say: Macs per day, versions, and how dictation, insertion, cleanup, Fix typos and
// suggestions went. Reads D1 through wrangler, so it runs on a Mac signed in to the account (npx wrangler login).
// Run from this folder: node readout.mjs [days], 14 days by default. It only reads.

import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const sum = (counts, names) => names.reduce((total, name) => total + (counts[name] ?? 0), 0);
const prefixed = (counts, prefix) => Object.keys(counts).filter((name) => name.startsWith(prefix));
const percent = (part, whole) => (whole ? `${Math.round((100 * part) / whole)}%` : "-");

const TYPO_FIXED = ["typoFix.outcome.fixed", "typoFix.outcome.insertionUnverified"];
const TYPO_NOT_RUN = ["empty", "oversized", "unreadableField", "fieldChanged", "selectionUnavailable", "unavailable",
    "timedOut", "failed", "cancelled", "blocked"].map((outcome) => `typoFix.outcome.${outcome}`);
const VERIFIED = ["insertion.accessibility", "insertion.unicode", "insertion.clipboard"];
const ACCEPTED = ["suggestion.action.acceptedVerified", "suggestion.action.acceptedUnverified"];

/// One day's or one window's counts as the numbers worth reading, from rows of {name, count}.
export function measures(counts) {
    const holds = sum(counts, prefixed(counts, "dictation."));
    const deliveries = sum(counts, prefixed(counts, "insertion."));
    const fixes = sum(counts, TYPO_FIXED);
    const shown = counts["suggestion.outcome.ready"] ?? 0;
    return {
        holds, completed: counts["dictation.completed"] ?? 0, deliveries, verified: sum(counts, VERIFIED),
        typoPresses: counts["typoFix.requested"] ?? 0, fixes, undone: counts["typoFix.outcome.undone"] ?? 0,
        rejected: counts["typoFix.outcome.rejected"] ?? 0, unchanged: counts["typoFix.outcome.unchanged"] ?? 0,
        notRun: sum(counts, TYPO_NOT_RUN), suggestions: counts["suggestion.requested"] ?? 0, shown, accepted: sum(counts, ACCEPTED),
    };
}

/// The readout as lines of text. `reports` rows are {day, app, os, arch, macs}; `usage` rows are {day, name, count}.
export function readout(reports, usage, days) {
    const lines = [`Jot analytics, last ${days} days`, ""];
    if (reports.length === 0) return [...lines, "No reports yet. A Mac sends a finished day after local midnight: a minute after Jot launches, then every six hours."];
    const byDay = new Map();
    const day = (key) => byDay.get(key) ?? byDay.set(key, { macs: 0, counts: {} }).get(key);
    for (const row of reports) day(row.day).macs += row.macs;
    for (const row of usage) day(row.day).counts[row.name] = (day(row.day).counts[row.name] ?? 0) + row.count;
    const window = {};
    for (const { counts } of byDay.values()) for (const [name, count] of Object.entries(counts)) window[name] = (window[name] ?? 0) + count;

    lines.push("day         macs  holds  ok    typo presses  fixed  undone  rejected  suggestions  accepted");
    for (const [key, { macs, counts }] of [...byDay].sort(([a], [b]) => b.localeCompare(a))) {
        const m = measures(counts);
        lines.push([key.padEnd(10), String(macs).padStart(5), String(m.holds).padStart(6), percent(m.completed, m.holds).padStart(5),
            String(m.typoPresses).padStart(13), String(m.fixes).padStart(6), String(m.undone).padStart(7), String(m.rejected).padStart(9),
            String(m.suggestions).padStart(12), String(m.accepted).padStart(9)].join(" "));
    }

    const versions = new Map();
    for (const row of reports) {
        const name = `${row.app} on macOS ${row.os} ${row.arch}`;
        versions.set(name, (versions.get(name) ?? 0) + row.macs);
    }
    lines.push("", "Versions (Mac-days)");
    for (const [name, macDays] of [...versions].sort(([, a], [, b]) => b - a)) lines.push(`  ${name}: ${macDays}`);

    const m = measures(window);
    const breakdown = (prefix) => prefixed(window, prefix).sort((a, b) => window[b] - window[a])
        .map((name) => `${name.slice(prefix.length)} ${window[name]}`).join(", ") || "none";
    lines.push("", "Dictation",
        `  ${m.holds} holds, ${percent(m.completed, m.holds)} completed. ${breakdown("dictation.")}`,
        `  ${m.deliveries} deliveries, ${percent(m.verified, m.deliveries)} verified. ${breakdown("insertion.")}`,
        `  Cleanup: ${breakdown("cleanup.dictation.")}. Live phrases: ${breakdown("cleanup.live.")}`,
        "", "Fix typos",
        `  ${m.typoPresses} presses: ${m.fixes} fixed, ${m.undone} undone (${percent(m.undone, m.fixes)} of fixes), ${m.rejected} rejected, ${m.unchanged} nothing to fix, ${m.notRun} could not run.`,
        `  ${breakdown("typoFix.outcome.")}`,
        "", "Suggestions",
        `  ${m.suggestions} requested, ${m.shown} shown, ${m.accepted} accepted (${percent(m.accepted, m.shown)} of shown).`,
        `  Ended by: ${breakdown("suggestion.action.")}`,
        "", "Saved dictation", `  ${breakdown("savedDictation.")}`);
    return lines;
}

/// Rows from one read-only query against the remote database.
function query(sql) {
    const output = execFileSync("npx", ["wrangler", "d1", "execute", "jot-analytics", "--remote", "--json", "--command", sql],
        { cwd: fileURLToPath(new URL(".", import.meta.url)), encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
    return JSON.parse(output).flatMap((result) => result.results ?? []);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const days = Number.parseInt(process.argv[2] ?? "14", 10);
    if (!(days > 0 && days <= 400)) { console.error("usage: node readout.mjs [days, 1-400]"); process.exit(2); }
    const since = `date('now','-${days} days')`;
    const reports = query(`SELECT day, app, os, arch, macs FROM reports WHERE day >= ${since}`);
    const usage = query(`SELECT day, name, SUM(count) AS count FROM usage WHERE day >= ${since} GROUP BY day, name`);
    console.log(readout(reports, usage, days).join("\n"));
}
