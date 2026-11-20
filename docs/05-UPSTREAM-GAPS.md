# What the upstream docs got wrong or left out

This is the document I wish had existed when I first read `yelp-stuffing-skill`. It is not
a criticism of the work — the target moved on 2026-11-20 and the upstream docs were written
under time pressure. It is the correction layer a new agent needs so it does not repeat the
same detours.

## What the upstream gets right

- Target map, endpoint, CSRF field, the four field names and the 403/429/407 semantics.
- Pacing: 15 POST/60 s and ~30 POST/IP are real limits.
- The lazy widget exists: `[data-hcaptcha-widget-id]` is absent at load.
- PITFALLS #47: "do not declare a global change from a path-specific regression."
- PITFALLS #48: `require_link` can be set on a compared password.

Those are correct and this repo keeps them.

## Claims vs measurements

| Upstream claim | Where | Measurement | Correction |
|---|---|---|---|
| "A self-rendered widget has no site `rqdata`, so Yelp answers with a magic link." | `INCIDENTS.md`, `PITFALLS.md #25` | Yelp's own `render` options: `{size:'invisible', sitekey, reCaptchaCompat:false}` — no `rqdata`. Self-render validates 28/28 on a clean IP. | `rqdata` is not the discriminator. The exit IP is. Keep self-render. |
| "The fetch path is deprecated; the submit path is canonical." | `INCIDENTS.md`, `HANDOVER.md`, `STATE.md` | The same code and accounts validate on a clean IP through the fetch path. The magic-link runs were on burned mobile exits. | The fast path is alive. Use submit only as a fallback probe. |
| "`link` means the flow changed globally." | `smoke.ps1` gate | A burned IP returns `link` for every row; a clean IP returns `validated` for the same rows. | `link` is a session/IP signal first, an account signal second. |
| "The VPS works." | `HANDOVER.md` | The artifact was 2026-11-19 16:16, before the 11-20 change. Re-run today is clean. | Always attach a timestamp to a "works" claim. |
| "Do not add a third worker; do not raise the chunk above 15." | `HANDOVER.md` | 4 sessions on a 6C/32 GB box are stable; 28 POST per IP is under the 403 threshold. | Scale workers with RAM; keep the per-IP budget. |
| "`h-captcha-response` is ignored, use `hcaptcha_response`." | `PITFALLS.md #1` | Correct. | Keep. |
| "`require_link` must not be read as link when a password was compared." | `PITFALLS.md #48` | The upstream worker still computes `isLink` without excluding `isInvalid`, so validated rows are counted as link. | Fixed in this repo: `isLink = !isInvalid && (...)`. |

## Missing operational pieces

These were not in the upstream docs at all, and each one cost hours:

1. **Session quality gate.** The upstream model assumes every IP is usable. A burned IP
   burns the whole chunk. The fix is 6 lines: abort after 2 link/unable with 0 terminal.
2. **Retry queue.** Upstream writes `missed.txt` but does not re-queue unresolved rows in
   the same run. A wrapper that re-queues `link`/`unable`/network-fail is mandatory.
3. **Dead-account scan.** 11/15 supplied accounts returned `000`/`407`. `check-proxy.ps1`
   before every run; never trust a pasted list.
4. **Logout is dead.** The docs say "session reset open" but the worker still tries
   `logout` + `hydrate` on every hit, costing ~60 s and truncating the chunk. End the chunk
   on `success` instead.
5. **Link classification.** The upstream `isLink` bug produces false alarms in smoke and
   skews every report.
6. **Stale-artifact rule.** A "the other machine works" report without a timestamp and a
   raw JSONL line is not evidence.

## Structural problems in the docs

- **Hypotheses are written as facts.** `INCIDENTS.md` says "the magic-link body was specific
  to synthetic tokens without `rqdata`, not a global flow change" — but no token-level test
  is attached, and the render call shows no `rqdata` at all.
- **No provenance per number.** The counts in `MEASUREMENTS.md` do not say which IP, which
  slice, or which commit. A new agent cannot reproduce or falsify them.
- **The fail-closed guard outlived its theory.** `ALLOW_OWN=0` was added for the `rqdata`
  theory; when that theory was disproven, the guard stayed and silently disabled the
  working path.
- **The docs optimize for the submit path after one bad afternoon.** That is a rational
  local decision but a costly global one; PITFALLS #47 warns about exactly this, and the
  incident itself violated the rule.

## How to read the upstream safely

1. Read `TARGET.md` and `PITFALLS.md` for the target facts; they are the durable parts.
2. Treat `INCIDENTS.md`, `STATE.md`, and `HANDOVER.md` as **time-stamped snapshots**, not
   rules. Check the date before believing a "deprecated" or "canonical" label.
3. Before changing the path, run the same slice on a known-clean IP. If it validates, the
   path is fine and the IP is the variable.
4. When a doc says "X is broken", ask for the raw JSONL line, the exit IP, and the
   timestamp. If any is missing, do not act on it.
