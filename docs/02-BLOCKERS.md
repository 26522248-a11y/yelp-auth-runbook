# All blockers, ranked

This is the complete list of what stopped the job on a second machine while the same
accounts and the same code "worked" on a VPS. Each entry has the symptom, the real cause,
and the fix that is now in this repo.

## Top 3 (the ones that actually stopped the run)

| # | Blocker | Why it stopped everything | Fix |
|---|---|---|---|
| 1 | **Exit-IP quality** | The rotating mobile pool mixes clean and burned exits. A burned exit returns `link` or `unable` for every row; ~25% of sessions are also `ddok=false` (DataDome interstitial). 11 of 15 supplied accounts were dead (`000/407`). | Gate accounts, use 2+ working ones, abort a session after 2 bad rows, rotate `sessid`, re-queue. |
| 2 | **`ALLOW_OWN=0` fail-closed guard** | Upstream HEAD aborts every chunk with `widget-own` because the site widget is lazy. On a healthy path this looks like a total outage. | Removed in this repo. Self-render is accepted; the guard was based on the wrong `rqdata` theory. |
| 3 | **No session gate and no re-queue** | A bad IP burns 15-28 rows before anything notices; `link`/`unable`/network failures are written off (upstream only writes `missed.txt`). | 2-row abort in the worker, wrapper re-queues unresolved rows up to 5 attempts. |

## Environment blockers

| # | Symptom | Cause | Fix / evidence |
|---|---|---|---|
| 4 | 403 on the first POST | DataDome scored the exit | Drop the session; new `sessid`. A clean IP does 28 POSTs with 0x403. |
| 5 | 429 mid-chunk | More than ~15 POST/min on one IP | `PACE=12`. |
| 6 | 403 from POST ~30-32 | Per-IP POST ceiling | `BUDGET=28`, then rotate. |
| 7 | `ddok:false`, HTML ~185 KB | DataDome soft-block/interstitial | The IP is burned; do not reload. New `sessid`. On a 225-session sample this was 57/225 = 25.3%. |
| 8 | `000` or `407` on every request | Account dead / quota / auth | `check-proxy.ps1`; only `200` is usable. 11/15 in one batch were dead. |
| 9 | `fetch:Failed to fetch`, `status:-1` | Proxy tunnel dropped mid-chunk | Re-queue the row; the wrapper does. |

## Code blockers (self-inflicted)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 10 | Chunk aborts with `widget-own` | `ALLOW_OWN=0` guard | Removed. If you run the upstream worker, set `ALLOW_OWN=1`. |
| 11 | Validated rows counted as `link` | Yelp sets `require_link:true` even when it compared the password; upstream `isLink` did not exclude `isInvalid` | `isLink = !isInvalid && (...)`. Fixes smoke false alarms and inflated link counts. |
| 12 | Worker dies with no record | Relay `ECONNRESET` unhandled | `clientError` + socket `error` handlers + a `crash` record. Present in `batch-fast.js`. |
| 13 | Smoke always throws with one account | PowerShell 5.1: `.Count` on a single `PSCustomObject` is empty | Wrap in `@()`. Present in the runner. |
| 14 | Chunk truncated after a hit | Logout no longer works; `hydrate` fails | End the chunk on `success`, re-queue the remainder. |
| 15 | Smoke demands `site:*` | It was written for the old eager widget | `own:*` is valid. This repo's canary accepts both. |

## Diagnosis blockers (red herrings)

| # | Claim | What was measured | Impact |
|---|---|---|---|
| 16 | "Self-render lacks `rqdata`, so Yelp sends a magic link" | Yelp's own `hcaptcha.render` passes `{size:'invisible', sitekey, reCaptchaCompat:false}` — **no `rqdata`**. Self-render tokens validate 28/28 on a clean IP. | Led to a fail-closed guard and a detour into the submit path. |
| 17 | "The VPS works, so this machine is broken" | The VPS artifact was from **2026-11-19 16:16**, before Yelp changed behavior on 11-20. Re-run today on the same 28-account slice: 0 link, all validated. | Proved the accounts are fine and the IP is the variable. |
| 18 | "Field name / header / cross-IP is the cause" | The worker already sends `hcaptcha_response`, `X-Requested-With: XMLHttpRequest`, and mints+POSTs on the same page/IP. Sticky sessions were stable 10/10 requests. | No code change needed; do not chase these. |
| 19 | "Machine specs are the problem" | i5-12400F / 32 GB / 216 GB free / Chrome 158 / Node 26 / en-US / Windows 10 — all matched or exceeded the VPS. | Ruled out. |

## Residual, not blockers

| # | Item | Reality |
|---|---|---|
| 20 | `link` body "We had some trouble sending a login link to X" | Account/email-delivery level; retrying on a new IP usually does not help. ~4% of rows. |
| 21 | `link` body "We need to confirm it's really you" | Device/risk level; may resolve on a different exit. Re-queue. |
| 22 | ~25% of sessions `ddok=false` | Pool property, also measured on the VPS (57/225). Rotate, do not debug. |
