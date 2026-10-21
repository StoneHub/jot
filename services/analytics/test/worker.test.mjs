// Run from this folder: npm test (Node 22.5 or later, for node:sqlite).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker, { validate, shiftDay, statements, MAX_BODY_BYTES } from "../src/worker.js";
import { COUNTERS } from "../src/counters.js";

/// A D1 stand-in over node:sqlite with the same prepare/bind/batch shape.
function database() {
    const db = new DatabaseSync(":memory:");
    db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
    return {
        raw: db,
        prepare(sql) { return { bind: (...values) => ({ run: () => db.prepare(sql).run(...values) }) }; },
        async batch(statements) {
            db.exec("BEGIN");
            try { for (const statement of statements) statement.run(); db.exec("COMMIT"); }
            catch (error) { db.exec("ROLLBACK"); throw error; }
        },
    };
}

const today = new Date(Date.now() + 14 * 3600 * 1000).toISOString().slice(0, 10);
const yesterday = shiftDay(today, -1);
const report = (overrides = {}) => ({ schema: 1, app: "0.3.4", os: "26.1", arch: "arm64",
    days: [{ day: yesterday, counters: { "dictation.completed": 3, "insertion.accessibility": 2, "insertion.failed": 0 } }], ...overrides });
const post = (body, path = "/v1/usage") => new Request(`https://jot-analytics.example${path}`,
    { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });

test("a report adds to aggregate rows and counts one Mac per day", async () => {
    const env = { DB: database() };
    assert.equal((await worker.fetch(post(report()), env)).status, 204);
    assert.equal((await worker.fetch(post(report()), env)).status, 204);
    const usage = env.DB.raw.prepare("SELECT name,count FROM usage ORDER BY name").all();
    assert.deepEqual(usage.map((row) => [row.name, row.count]), [["dictation.completed", 6], ["insertion.accessibility", 4]]);
    const reports = env.DB.raw.prepare("SELECT day,app,os,arch,macs FROM reports").all();
    assert.deepEqual(reports.map((row) => ({ ...row })), [{ day: yesterday, app: "0.3.4", os: "26.1", arch: "arm64", macs: 2 }]);
});

test("nothing that could identify a Mac or hold text is accepted", () => {
    const refused = [
        report({ installID: "abc" }),
        report({ arch: "Monroe's MacBook" }),
        report({ app: "0.3.4 (hello)" }),
        report({ app: "0.3.4-beta" }),
        report({ os: "Darwin" }),
        report({ days: [{ day: yesterday, counters: { "dictation.madeUp": 1 } }] }),
        report({ days: [{ day: yesterday, counters: { "transcript text here": 1 } }] }),
        report({ days: [{ day: yesterday, counters: { "dictation.completed": 1.5 } }] }),
        report({ days: [{ day: yesterday, counters: { "dictation.completed": -1 } }] }),
        report({ days: [{ day: yesterday, counters: {}, app: "com.example" }] }),
        report({ days: [{ day: shiftDay(today, 1), counters: {} }] }),
        report({ days: [{ day: shiftDay(today, -40), counters: {} }] }),
        report({ days: [{ day: yesterday, counters: {} }, { day: yesterday, counters: {} }] }),
        report({ days: [] }),
        report({ schema: 2 }),
        [],
    ];
    for (const body of refused) assert.ok(validate(body, today).error, JSON.stringify(body));
    assert.equal(validate(report(), today).error, undefined);
});

test("a week of reports with every counter is two statements per day", async () => {
    const env = { DB: database() };
    const counters = Object.fromEntries([...COUNTERS].map((name) => [name, 1]));
    const days = Array.from({ length: 7 }, (_, index) => ({ day: shiftDay(today, -1 - index), counters }));
    const body = report({ days });
    assert.equal(validate(body, today).error, undefined);
    assert.equal(statements(env.DB, body).length, 14);
    assert.equal((await worker.fetch(post(body), env)).status, 204);
    assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM usage").get().n, 7 * COUNTERS.size);
});

test("wrong paths, methods, oversized and malformed bodies are refused", async () => {
    const env = { DB: database() };
    assert.equal((await worker.fetch(post(report(), "/"), env)).status, 404);
    assert.equal((await worker.fetch(new Request("https://jot-analytics.example/v1/usage"), env)).status, 405);
    assert.equal((await worker.fetch(post("{"), env)).status, 400);
    assert.equal((await worker.fetch(post("x".repeat(MAX_BODY_BYTES + 1)), env)).status, 413);
    const declared = new Request("https://jot-analytics.example/v1/usage",
        { method: "POST", body: "{}", headers: { "content-length": String(MAX_BODY_BYTES + 1) } });
    assert.equal((await worker.fetch(declared, env)).status, 413);
    assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM reports").get().n, 0);
});
