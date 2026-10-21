# Jot analytics Worker

A Cloudflare Worker that receives Jot's anonymous daily usage counts and adds them to two aggregate tables in D1. What Jot sends, and what it never sends, is described in [docs/ANALYTICS.md](../../docs/ANALYTICS.md).

The Worker stores no IP address, install ID, user agent or text, and request logging is off. It keeps no row per request: each report adds to per-day totals, so two reports cannot be linked to one Mac.

| Table | Row | Meaning |
| --- | --- | --- |
| `usage` | day, counter name, Jot version, macOS version, arch | How many times that counter happened that day, summed over every Mac that reported. |
| `reports` | day, Jot version, macOS version, arch | How many Macs reported that day. |

## Deploy (once)

Jot's Worker is already deployed: `wrangler.toml` holds its D1 `database_id`, and `UsageReport.endpoint` holds its URL. To redeploy after changing `src/`, run `npx wrangler deploy` from this folder.

To set it up on a new Cloudflare account, you need Node 18 or later. Run the steps in two blocks, because the second block needs an id that the first one prints. First, from a Mac:

```sh
cd ~/Developer/jot/services/analytics && npx wrangler login
cd ~/Developer/jot/services/analytics && npx wrangler d1 create jot-analytics
```

Put the `database_id` it prints into `wrangler.toml`, replacing the current one. Then run:

```sh
cd ~/Developer/jot/services/analytics && npx wrangler d1 execute jot-analytics --remote --yes --command "$(grep -v '^--' schema.sql)"
cd ~/Developer/jot/services/analytics && npx wrangler d1 execute jot-analytics --remote --command "SELECT name FROM sqlite_master WHERE type='table'"
cd ~/Developer/jot/services/analytics && npx wrangler deploy
```

The second line should list `usage` and `reports`. The deploy prints the Worker's `https://jot-analytics.<account>.workers.dev` URL. Set `UsageReport.endpoint` to that URL plus `/v1/usage`.

The schema goes in with `--command` rather than `--file`, for two reasons:
- `--file` goes through D1's import API, which returned an authentication error for an OAuth login on 2026-10-21.
- The comment lines are dropped first because wrangler reads a `--command` value that starts with `--` as a flag.

Free-plan limits (100,000 Worker requests and 100,000 D1 row writes a day at the time of writing) cover one report per Mac per day for thousands of Macs.

## Look at the numbers

```sh
cd ~/Developer/jot/services/analytics
npx wrangler d1 execute jot-analytics --remote --command "SELECT day, SUM(macs) AS macs FROM reports GROUP BY day ORDER BY day DESC LIMIT 14"
npx wrangler d1 execute jot-analytics --remote --command "SELECT name, SUM(count) AS total FROM usage WHERE day >= date('now','-7 days') GROUP BY name ORDER BY total DESC"
```

## Test

```sh
cd services/analytics && npm test
```

The tests run the Worker against `node:sqlite` with `schema.sql`, so they need Node 22.5 or later and no install.
