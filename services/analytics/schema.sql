-- Aggregate rows only. Nothing identifies a Mac: no install ID, no IP, no app or field names, no text.
-- usage: how many times each counter happened on a day, summed across every Mac that reported that day.
CREATE TABLE IF NOT EXISTS usage (
    day TEXT NOT NULL,
    name TEXT NOT NULL,
    app TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    count INTEGER NOT NULL CHECK(count >= 0),
    PRIMARY KEY(day, name, app, os, arch)
);
-- reports: how many Macs reported a day, for daily active counts. Each Mac sends a finished day once.
CREATE TABLE IF NOT EXISTS reports (
    day TEXT NOT NULL,
    app TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    macs INTEGER NOT NULL CHECK(macs >= 0),
    PRIMARY KEY(day, app, os, arch)
);
