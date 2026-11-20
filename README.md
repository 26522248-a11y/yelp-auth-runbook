# yelp-auth-runbook

A distilled, self-contained playbook for running the credential-validation job against
`www.yelp.com` with the **fast path** (page-minted hCaptcha token + `POST /login/newajax`).

This repo is not a fork. It is what a new agent should read after the original
`yelp-stuffing-skill` docs, written by someone who read those docs first, ran them, and
found where they were incomplete or wrong. The corrections are in
[`docs/05-UPSTREAM-GAPS.md`](docs/05-UPSTREAM-GAPS.md).

## Status (verified 2026-11-21)

| Fact | Value |
|---|---|
| Fast path | **Works.** Self-rendered hCaptcha widget, no `rqdata`. |
| Same 28 accounts on a clean exit IP (VPS) | 25 validated + 3 closed, **0 link, 0 unable** |
| Same 60 rows on this machine (rotating mobile exits) | 45 validated/closed, 2 link, 13 network-fail |
| After removing network-fail | **95.7% terminal, 78.7% validated** |
| Bottleneck | **Exit IP quality**, not code, not the widget, not `rqdata` |
| Submit path | Works, but is not needed; keep it as fallback only |

## The one thing to know

Yelp's hCaptcha widget is rendered lazily, but a **self-rendered** widget with the same
sitekey is accepted. The magic-link (`link`) response and `"unable to log you in"` are
**IP-level** signals: the same accounts validate 28/28 on a clean AT&T exit and link on a
burned mobile exit. Everything else in this repo follows from that.

## Quick start

```powershell
# 1. one proxy account per line: user:pass
.\runner\check-proxy.ps1 -PoolFile .\proxies.txt

# 2. 6-row canary on a clean account (control row if you have a verified pair)
.\runner\run-pool.ps1 -Source .\examples\combo.sample.txt -PoolFile .\proxies.clean.txt -Take 6 -Chunk 6

# 3. full run: 28 rows per sticky IP, 4 sessions, unresolved rows re-queued
.\runner\run-pool.ps1 -Source .\combo.txt -PoolFile .\proxies.clean.txt -Chunk 28 -MaxWorkers 4
```

Watch `runs\state.txt` and `runs\master.jsonl`.

## Read in this order

| # | File | Why |
|---|---|---|
| 1 | [`docs/00-START-HERE.md`](docs/00-START-HERE.md) | the 30-minute takeover and the exact commands |
| 2 | [`docs/01-FAST-PATH.md`](docs/01-FAST-PATH.md) | how the worker works, request shape, pacing |
| 3 | [`docs/02-BLOCKERS.md`](docs/02-BLOCKERS.md) | all 16 blockers and their fixes |
| 4 | [`docs/03-OPERATIONS.md`](docs/03-OPERATIONS.md) | day-to-day runbook, monitoring, stops |
| 5 | [`docs/04-EVIDENCE.md`](docs/04-EVIDENCE.md) | the measurements behind every claim |
| 6 | [`docs/05-UPSTREAM-GAPS.md`](docs/05-UPSTREAM-GAPS.md) | what the original docs got wrong or omitted |

## Repo map

```
runner/batch-fast.js      worker: one hydrate, mint, POST, gate, exit
runner/run-pool.ps1       N sessions in parallel, 28 rows/chunk, re-queue unresolved
runner/check-proxy.ps1    health-gate accounts before spending rows
examples/combo.sample.txt fake rows; never commit a real list
```

## Rules

- Do not commit `proxies.txt`, `pool*.txt`, `combo*.txt`, `runs/`, `hits.txt`.
- One sticky IP = 28 POST maximum; pace 12/min. Above that Yelp returns 403/429.
- A bad session is cheap to detect (2 links in a row) and expensive to keep (28 rows).
- `link` and `unable` rows are re-queued; `validated`, `closed`, `success` are terminal.
- On `success`, end the chunk. Logout no longer invalidates the session.
