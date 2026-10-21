// Receives Jot's anonymous daily usage counts and adds them to aggregate rows in D1.
// It stores no IP address, install ID, user agent or text: only counter names, counts and version strings,
// and it keeps no per-request row, so two reports can never be linked to one Mac.

import { COUNTERS } from "./counters.js";

export const MAX_BODY_BYTES = 16 * 1024;
export const MAX_DAYS = 7;
export const MAX_COUNT = 100_000;
/// How far back a finished day may be, so a Mac that slept for a week still reports it.
export const MAX_AGE_DAYS = 35;

const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const ARCH = new Set(["arm64", "x86_64"]);
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/// The report, or a reason it was refused. `today` is the server's UTC date as yyyy-mm-dd.
export function validate(body, today) {
    if (typeof body !== "object" || body === null || Array.isArray(body)) return { error: "body must be an object" };
    const keys = Object.keys(body).sort().join(",");
    if (keys !== "app,arch,days,os,schema") return { error: "unexpected fields" };
    if (body.schema !== 1) return { error: "unsupported schema" };
    if (typeof body.app !== "string" || !VERSION.test(body.app)) return { error: "invalid app version" };
    if (typeof body.os !== "string" || !VERSION.test(body.os)) return { error: "invalid os version" };
    if (!ARCH.has(body.arch)) return { error: "invalid arch" };
    if (!Array.isArray(body.days) || body.days.length === 0 || body.days.length > MAX_DAYS) return { error: "invalid days" };
    const oldest = shiftDay(today, -MAX_AGE_DAYS);
    const seen = new Set();
    for (const entry of body.days) {
        if (typeof entry !== "object" || entry === null || Object.keys(entry).sort().join(",") !== "counters,day") return { error: "invalid day" };
        // A day is reported once it has finished on the Mac. Local midnight can be up to 14 hours ahead of UTC.
        if (typeof entry.day !== "string" || !DAY.test(entry.day) || entry.day < oldest || entry.day > today || seen.has(entry.day)) return { error: "invalid day" };
        seen.add(entry.day);
        const counters = entry.counters;
        if (typeof counters !== "object" || counters === null || Array.isArray(counters)) return { error: "invalid counters" };
        const names = Object.keys(counters);
        if (names.length > COUNTERS.size) return { error: "too many counters" };
        for (const name of names) {
            const count = counters[name];
            if (!COUNTERS.has(name)) return { error: "unknown counter name" };
            if (!Number.isInteger(count) || count < 0 || count > MAX_COUNT) return { error: "invalid count" };
        }
    }
    return { report: body };
}

export function shiftDay(day, offset) {
    const date = new Date(`${day}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + offset);
    return date.toISOString().slice(0, 10);
}

/// Two statements per day, whatever the number of counters, so a week of reports stays far below D1's
/// per-invocation statement limit. The day's counters go in as one validated JSON object read by json_each.
export function statements(db, report) {
    const { app, os, arch } = report;
    return report.days.flatMap(({ day, counters }) => [
        db.prepare("INSERT INTO reports(day,app,os,arch,macs) VALUES(?1,?2,?3,?4,1) ON CONFLICT(day,app,os,arch) DO UPDATE SET macs=macs+1")
            .bind(day, app, os, arch),
        db.prepare("INSERT INTO usage(day,name,app,os,arch,count) SELECT ?1,key,?2,?3,?4,value FROM json_each(?5) WHERE value > 0 ON CONFLICT(day,name,app,os,arch) DO UPDATE SET count=count+excluded.count")
            .bind(day, app, os, arch, JSON.stringify(counters)),
    ]);
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        if (url.pathname !== "/v1/usage") return new Response(null, { status: 404 });
        if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
        // Refuse a declared oversized body before reading it; a body without a length is checked once read.
        if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return new Response("too large", { status: 413 });
        const text = await request.text();
        if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return new Response("too large", { status: 413 });
        let body;
        try { body = JSON.parse(text); } catch { return new Response("invalid json", { status: 400 }); }
        const today = new Date(Date.now() + 14 * 3600 * 1000).toISOString().slice(0, 10);
        const { report, error } = validate(body, today);
        if (error) return new Response(error, { status: 400 });
        await env.DB.batch(statements(env.DB, report));
        return new Response(null, { status: 204 });
    },
};
