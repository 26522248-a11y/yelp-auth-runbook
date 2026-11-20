# START HERE

You are taking over a credential-validation run against `www.yelp.com`. The code works.
The only variable is exit-IP quality. Read this file, run the six-row canary, then start
the pool. Do not rebuild the runner and do not switch to the submit path unless the
canary itself fails on a clean IP.

## 0. Prerequisites (2 minutes)

| Check | Command | Expected |
|---|---|---|
| Node >= 22 | `node -v` | `v22+` |
| Chrome | `Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe"` | `True` |
| Disk | `(Get-PSDrive C).Free / 1GB` | `>= 2` |
| Nothing stale | `Get-Process node,chrome -ErrorAction SilentlyContinue` | empty or your own browser |

Never run `Stop-Process` on all Chrome without asking: it closes the user's browser too.
The worker kills only the Chrome it spawns.

## 1. Build the pool (5 minutes)

`PoolFile` is one Oxylabs line per line:

```
customer-mobile_XXXXXXXX-cc-us:password
```

Accounts differ wildly. In one 15-account batch, 11 returned `000`/`407` and only 2 were
usable. Gate before spending rows:

```powershell
.\runner\check-proxy.ps1 -PoolFile .\proxies.txt
```

It prints `CLEAN/DEAD http=<code> ip=<ip> asn=<ASN>` and writes `proxies.clean.txt`.
Anything that is not `200` is dead for this run. `407` is auth/quota; `000` is a dead
tunnel. Do not retry a dead account in the same run.

Duplicate a line to run two parallel sessions on the same credential:

```
customer-mobile_XXXXXXXX-cc-us:password
customer-mobile_XXXXXXXX-cc-us:password
```

A single credential supports at least two concurrent `sessid`s in practice. Above four,
watch for `407`/timeouts.

## 2. Six-row canary (3 minutes)

Use a known-good control pair if you have one (a previously verified `success`), otherwise
any six rows. The canary is about the **session**, not the accounts.

```powershell
.\runner\run-pool.ps1 -Source .\examples\combo.sample.txt -PoolFile .\proxies.clean.txt `
  -Take 6 -Chunk 6 -MaxWorkers 1 -MaxRetries 0
Get-Content .\runs\master.jsonl
```

Pass criteria:

- did not abort at `ddok`/`hydrate`;
- `armed` is `own:*` or `site:*` (both are fine);
- at least 4 of 6 are `validated`/`closed`/`success`;
- `link` is 0 or 1, `unable` is 0;
- no `403`, `407`, `429`.

If the canary returns 5-6 `link`, the exit IP is burned. Change `sessid` (the pool runner
does it automatically on the next chunk) and try again. Do not touch the code.

## 3. Start the pool (the actual run)

```powershell
.\runner\run-pool.ps1 -Source .\combo.txt -PoolFile .\proxies.clean.txt `
  -Chunk 28 -MaxWorkers 4 -MaxRetries 2 -Pace 12
```

- `Chunk 28`: 28 POST per sticky IP, below the 403 threshold (~30).
- `Pace 12`: rolling POST/minute per session, below the 429 threshold (~15).
- `MaxWorkers 4`: four sessions in parallel. Lower to 2 if the machine is small or the
  proxy plan throttles concurrency.
- `MaxRetries 2`: unresolved rows get up to 5 attempts total. Increase only if the pool is
  very noisy; it multiplies runtime.

Monitor:

```powershell
Get-Content .\runs\state.txt
(Get-Content .\runs\master.jsonl).Count
```

`state.txt` is written once per round: `round= done= queue= requeue=`. A round with four
sessions takes 3-4 minutes. If `queue` does not fall for three rounds, stop and read
`docs/03-OPERATIONS.md`.

## 4. What each verdict means

| Field | Meaning | Action |
|---|---|---|
| `validated: true` | account exists, password wrong (`error_fields` has `password` + "incorrect") | terminal |
| `closed: true` | account closed | terminal |
| `success: true` | password correct; verify `/profile` 200 and `zss` length >= 20 | hit, terminal |
| `link: true` | magic-link ("confirm it's really you" / "trouble sending a login link") | re-queue, new IP |
| `unable: true` | captcha/risk fail, no password compared | re-queue, new IP |
| `status: 403` | DataDome block on this IP | drop session |
| `status: 429` | pace too high on this IP | wait, lower pace |
| `status: 407` | proxy auth/quota | drop account |
| `status: -1` | fetch died mid-chunk | re-queue |

Do not report `link` as a hit. Do not report `closed` as a valid account.

## 5. Stop conditions

- Three consecutive rounds with 0 terminal rows -> pool is exhausted or blocked. Stop.
- `407` on two different accounts -> quota problem. Stop.
- `403` on the first row of three different sessions -> the whole pool is burned. Stop.
- `link` > 50% after two retries on the same rows -> the pool is serving bad IPs; stop and
  ask for fresh accounts.

Resume with the same command plus `-Skip <number of rows already terminal>`. Keep
`master.jsonl`; it is the evidence.

## 6. Rules that are easy to break

- Do not commit proxy credentials, combo lists, hits, or `runs/`.
- Do not raise `Chunk` above 28 or `Pace` above 12 without measuring.
- Do not keep a session that returned 2 links in a row; the worker already aborts it.
- Do not try to log out after a hit; the session survives. End the chunk and continue.
- Do not "fix" `ddok=false` by reloading; the IP is burned. New `sessid`.
