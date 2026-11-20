# Runner

| Script | Use |
|---|---|
| `check-proxy.ps1` | gate pool accounts; only `200` on `/login/` is CLEAN |
| `run-pool.ps1` | the run: N sessions, 28-row chunks, re-queue unresolved |
| `batch-fast.js` | the worker; call it directly only for a one-row debug |

## Pool file

```
customer-mobile_XXXXXXXX-cc-us:password
```

One account per line. Duplicate a line to run two sessions on it. Non-Oxylabs static
proxies: set `-PuSuffix none` on `run-pool.ps1` and pass the plain `user:pass`; no session
suffix is appended.

## Commands

```powershell
# health gate
.\runner\check-proxy.ps1 -PoolFile .\proxies.txt

# six-row canary
.\runner\run-pool.ps1 -Source .\examples\combo.sample.txt -PoolFile .\proxies.clean.txt `
  -Take 6 -Chunk 6 -MaxWorkers 1 -MaxRetries 0

# full run
.\runner\run-pool.ps1 -Source .\combo.txt -PoolFile .\proxies.clean.txt `
  -Chunk 28 -MaxWorkers 4 -MaxRetries 2 -Pace 12
```

## Output

- `runs/master.jsonl` — every record (append-only within a run)
- `runs/state.txt` — `round= done= queue= requeue=`
- `runs/chunk_XXXX_Y.jsonl` — one file per session, plus `.log`

## Worker env

`BID LIST OUT PU_BASE PW SESS PU_SUFFIX PACE BUDGET MAXT PROXY_HOST PROXY_PORT`

Defaults: `PACE=12`, `BUDGET=28`, `PU_SUFFIX=-sesstime-1800`, `PROXY_HOST=pr.oxylabs.io`,
`PROXY_PORT=7777`. Set `PU_SUFFIX=none` for a static proxy.

## One-row debug

```powershell
$env:BID=0; $env:LIST=".\one.txt"; $env:OUT=".\one.jsonl"
$env:PU_BASE="customer-mobile_XXXX-cc-us"; $env:PW="..."
$env:PACE=12; $env:BUDGET=1
node .\runner\batch-fast.js
```

Exit codes: worker exits 0 even when rows fail; read the JSONL. `process.exit(2)` is a disk
guard, `process.exit(3)` is an uncaught crash (a `crash` record is written first).
