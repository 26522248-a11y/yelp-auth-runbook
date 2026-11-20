# Operations

## Files

```
runner/batch-fast.js     worker; reads env, writes one JSONL record per row
runner/run-pool.ps1      parallel sessions, chunking, retry queue, state file
runner/check-proxy.ps1   account health gate, writes proxies.clean.txt
runs/                    output (gitignored)
  master.jsonl           every record from every attempt
  state.txt              round= done= queue= requeue=
  chunk_XXXX_Y.jsonl     one per session
  chunk_XXXX_Y.jsonl.log worker stdout/stderr
```

## Environment for a single worker

`batch-fast.js` reads:

| Var | Meaning | Default |
|---|---|---|
| `BID` | slot id; sets relay/CDP ports (8986+BID, 9306+BID) | 0 |
| `LIST` | input file, `email:password` per line | required |
| `OUT` | output JSONL | required |
| `PU_BASE` | proxy username without the session suffix | required |
| `PW` | proxy password | required |
| `SESS` | sticky session id | random |
| `PU_SUFFIX` | `-sesstime-1800` by default; `none` for a static proxy | `-sesstime-1800` |
| `PROXY_HOST` / `PROXY_PORT` | proxy endpoint | `pr.oxylabs.io:7777` |
| `PACE` | max POST per rolling minute per IP | 12 |
| `BUDGET` | max POST per sticky IP | 28 |
| `MAXT` | wall-clock cap per worker (ms) | 900000 |

Single-session debug:

```powershell
$env:BID=0; $env:LIST=".\one.txt"; $env:OUT=".\one.jsonl"
$env:PU_BASE="customer-mobile_XXXX-cc-us"; $env:PW="..."
$env:PACE=12; $env:BUDGET=1
node .\runner\batch-fast.js
```

`BUDGET=1` and one row is the cheapest way to test a fresh account; it costs one POST.

## Pool hygiene

- One line = one Oxylabs account. `check-proxy.ps1` keeps only `200`.
- Duplicate a line to run two sessions on one account.
- A session (`sessid`) pins one exit IP for `sesstime`. 30 minutes is enough for 28 POSTs;
  the POST budget expires first.
- Different `sessid` = different IP = fresh risk score. Use it after `ddok:false`, `403`,
  two `link`s, or a `429` streak.
- Do not reuse a burned `sessid` in the same run.

## Monitoring a run

```powershell
Get-Content .\runs\state.txt
$rows = Get-Content .\runs\master.jsonl | ForEach-Object { $_ | ConvertFrom-Json }
$rows | Group-Object { if ($_.success) {'success'} elseif ($_.validated) {'validated'} elseif ($_.closed) {'closed'} elseif ($_.link) {'link'} elseif ($_.unable) {'unable'} else {'none'} } | Select-Object Name,Count
Get-Content .\runs\master.jsonl | Select-String '"success":true'
```

Expected steady state on a healthy pool:

- `validated` 60-80% of terminal rows;
- `closed` 5-15%;
- `link` < 5%;
- `unable` ~0;
- `403/429/407` ~0;
- one `success` every ~80-200 rows (list-dependent).

## Hits

A `success` record contains the pair and the evidence:

```json
{"email":"x@y.com","pass":"...","success":true,"profileStatus":200,"zss":[{"d":".yelp.com","len":30}],"zssLen":30}
```

Accept a hit only if `profileStatus === 200` **and** `zssLen >= 20`. Append
`email:pass` to `hits.txt` (gitignored). Do not paste hit pairs into docs or issues.

On a hit the worker ends the chunk. The rows after it are re-queued by the wrapper; that is
expected, not data loss.

## Resume

The wrapper always starts from `-Skip` and rebuilds the queue. To resume:

1. Count terminal rows in `master.jsonl` (or use `-Skip` equal to the number of input rows
   already processed).
2. Run the same command with `-Skip <n>`.
3. Keep `master.jsonl`; append-only per run.

If a run is interrupted mid-round, the unfinished rows are simply attempted again. That is
cheaper than reconciling a half-written chunk.

## Stop / rotate table

| Signal | Meaning | Action |
|---|---|---|
| `ddok:false` | burned IP | new `sessid` |
| first row `403` | burned IP | new `sessid` |
| `429` | pace | sleep 13 s, lower `PACE` |
| `407` | auth/quota | remove account |
| 2 links in a row, 0 terminal | burned IP | gate already aborts; new `sessid` |
| `fetch:Failed to fetch` | tunnel dropped | re-queue; if repeated, drop account |
| 3 rounds with 0 terminal | pool exhausted | stop, request proxies |
| `link` > 50% after retries | pool serving bad IPs | stop, request proxies |

## Disk and cleanup

The worker guards on 2 GB free and removes its `%TEMP%\cdp-*` profile on exit. If a run is
killed, delete `%TEMP%\cdp-*` manually. Each Chrome is ~300-500 MB; four sessions on a
32 GB box is fine.

## Reporting template

```
round=<n> done=<n> queue=<n>
validated=<n> closed=<n> success=<n> link=<n> unable=<n> 403=<n> 429=<n> 407=<n>
rate=<rows/min> pool_clean=<n> next=<skip>
hits: email:pass (profile=200 zss=<len>)
```
