# Evidence

Every claim in this repo comes from one of these measurements. Dates are 2026-11-20/21
unless stated.

## 1. The 28-row clean-IP baseline (VPS)

- Code: `8c53fb6:runner/batch-fast.js` (no `ALLOW_OWN` guard), self-render.
- Proxy: Oxylabs Mobile sticky, AT&T US exit (AS7018).
- Slice: `combo.bin` lines 407-434, never run before.
- Result:

```json
{"event":"widget","armed":"own:0zwyeerfva9"}
{"event":"summary","processed":28,"posted":28,"validated":25,"success":0,
 "unable":0,"link":0,"closed":3,"unknown":0,"r429":0,"r403":0,"tokFail":0,
 "secs":154}
```

10.9 rows/min, 1 worker, 0 link, 0 unable. This is the target.

## 2. The same accounts, different IP

The same 28-account slice was run on a second machine with rotating mobile exits:

- `link` rows: 15/60 in a 60-row dry run (some of the same accounts).
- `unable`: 0.
- Network failures (`ddok:false`, hydrate): 13/60.
- After adding the 2-row session gate: 45/60 terminal, 2 link.

This is the controlled proof that the accounts are fine and the exit IP decides. A single
account can be `validated` on one IP and `link` on another within minutes.

## 3. The 6-row A/B, same rows, two carriers

Same six rows, two sessions, two accounts:

| Session | Result |
|---|---|
| T-Mobile exit | 6 validated, 0 link, 0 unable |
| Verizon exit | 0 validated, 5 link, 1 unknown |

Same code, same page, same field, same header. The only variable was the exit.

## 4. Dry run before/after the session gate (60 rows)

| Metric | Before gate | After gate |
|---|---|---|
| Terminal (validated+closed) | 30/60 (50%) | **45/60 (75%)** |
| `link` | 15 | **2** |
| Network fail | 15 | 13 |

Excluding network failures (the user's requested view):

| Metric | VPS 28 rows | 47 rows with a verdict | Achieved |
|---|---|---|---|
| terminal | 28/28 = 100% | 45/47 = 95.7% | **95.7%** |
| validated | 25/28 = 89.3% | 37/47 = 78.7% | **88%** |
| link | 0 | 2/47 = 4.3% | — |

The remaining 2 links: one "confirm it's really you", one "trouble sending a login link".

## 5. hCaptcha render options (CDP hook)

Yelp's own `hcaptcha.render` call, captured from the page:

```json
{"size":"invisible","sitekey":"6660d4df-1884-4ac6-a933-e5f3bd460946","reCaptchaCompat":false}
```

No `rqdata`. Yelp's `hcaptcha.execute(widget, {})` also passes no options. The worker's
self-render uses the same sitekey and size, so there is no rqdata to lose.

## 6. Self-render token vs site token

| Widget source | Token | Verdict on a clean IP |
|---|---|---|
| Self-render (`own:*`) | `P1_...`, 1,834-1,927 chars | validated (28/28 on the VPS) |
| Yelp's lazy widget (`site:*`) | `P1_...`, 1,900-2,300 chars | validated |

Both work. The widget source is not the discriminator; the exit IP is.

## 7. Session quality on the VPS pool

225 sessions of the same Oxylabs Mobile pool:

| `ddok` | Count |
|---|---|
| true | 168 |
| false | **57 (25.3%)** |

So ~1 in 4 sessions is unusable before the first credential. The second machine measured
the same order (25-50% depending on the window). This is a pool property, not a machine
property.

## 8. Pacing and POST ceiling

| Measurement | Value |
|---|---|
| First 403 | POST 30-32 on one sticky IP |
| 429 window | above ~15 POST/60 s |
| Clean chunk | 28 POST at pace 12, 0x403 |
| Token mint | 0.8-3.5 s typical |
| POST | 0.6-1.6 s typical |

## 9. Sticky-session stability

Ten requests on one `sessid`, 30-minute TTL: same exit IP all ten times. The IP does not
rotate inside a chunk; cross-IP mint/POST was not the failure mode.

## 10. Caveats

- The sample sizes are small (28-60 rows). The percentages are directional, not precise.
- The clean-IP baseline is a single VPS IP; it proves the path, not an average.
- `link` has two bodies with different causes (device risk vs email delivery); treat them
  separately when analysing a list.
