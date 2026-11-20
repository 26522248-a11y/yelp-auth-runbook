# The fast path

One Chrome, one hydrated `/login/` page, one hCaptcha token per row, one XHR per row.
No form fill, no click, no navigation per credential.

## Flow

```
Node worker
  ├─ local HTTP CONNECT relay 127.0.0.1:8986+BID
  │     └─ Oxylabs sticky session -> exit IP
  ├─ Chrome (headful, fresh --user-data-dir, --remote-debugging-port 9306+BID)
  │     └─ https://www.yelp.com/login/
  ├─ CDP Runtime.evaluate:
  │     1. hydrate: #ajax-login + window.hcaptcha + outerHTML > 400k
  │     2. armWidget: use [data-hcaptcha-widget-id] if present, else render our own
  │     3. per row: reset+execute -> poll getResponse -> token
  │     4. fetch POST /login/newajax with csrftok, email, password, hcaptcha_response
  └─ append one JSONL record per row
```

The page must be hydrated (`#ajax-login` exists, `window.hcaptcha` loaded, HTML > 400 KB).
If DataDome serves an interstitial, the page is 180-200 KB and the worker aborts with
`ddok:false`. That is an IP problem, not a code problem.

## The request

```
POST https://www.yelp.com/login/newajax
Content-Type: application/x-www-form-urlencoded
X-Requested-With: XMLHttpRequest
Cookie: <page cookies>

csrftok=<64 hex>&email=<urlencoded>&password=<urlencoded>&hcaptcha_response=<P1_...>
```

`csrftok` comes from `#ajax-login input[name=csrftok]` and is stable for the page.

Field name is **`hcaptcha_response` with underscores**. The hyphenated
`h-captcha-response` is ignored by the endpoint. Sending both does not help; send the
underscore one.

The header `X-Requested-With: XMLHttpRequest` matters in practice: a missing header is
associated with DataDome 403s, not with a token verdict.

Mint and POST must happen on the same page and therefore the same exit IP. Do not mint on
one session and POST on another; that is the classic magic-link signature.

## hCaptcha

- Sitekey: `6660d4df-1884-4ac6-a933-e5f3bd460946` (from `yConfig.hcaptchaSitekey`).
- Yelp renders it lazily, only when its submit handler runs. At page load
  `[data-hcaptcha-widget-id]` is absent.
- **Self-rendering is accepted.** The worker creates a hidden `div#__fcap` and calls
  `hcaptcha.render(div, {sitekey, size:'invisible'})`. If Yelp's own widget happens to be
  in the DOM, the worker uses it instead.
- Yelp's own `render` call passes `{size:'invisible', sitekey, reCaptchaCompat:false}` —
  **no `rqdata`**. The claim "self-render lacks rqdata and is therefore rejected" is not
  supported; see `docs/05-UPSTREAM-GAPS.md`.
- Mint loop: `hcaptcha.reset(w); hcaptcha.execute(w);` then poll
  `hcaptcha.getResponse(w)` every 150 ms for up to 24 s. Tokens are `P1_...`, 1.8-2.3 KB.
- `hcaptcha.reset()` before each execute is required once the widget has produced a token;
  without it the second execute can return `[object Object]` or nothing.

## Pacing and budget

Yelp limits are per exit IP:

| Limit | Measured | Setting |
|---|---|---|
| POST/minute | 429 above ~15 | `PACE=12` |
| POST per sticky IP | 403 from ~30-32 | `BUDGET=28` |

28 rows at 12/min is ~2.3 minutes, plus ~40 s of hydration. A session lives 30 minutes
(`-sesstime-1800`), so the POST budget is the binding limit.

## Session quality gate

A burned IP returns `link` (or `unable`) for **every** row, including accounts that
validate elsewhere. Running 28 rows on it is pure waste. The worker aborts a session when
the first two rows produce two `link`/`unable` and zero `validated`/`closed`/`success`:

```js
if (i === 1 && validated + closed + success === 0 && link + unable >= 2) {
  rec({ event: 'session_bad', at: 2, link, unable });
  blocked = true;
}
```

Cost of a false positive: 2 rows, re-queued on the next session. Cost without the gate:
28 rows. Keep the gate.

## Success handling

`success` returns a JSON body and sets the session cookie. Logout no longer invalidates
it: `/logout?return_url=` still leaves `/profile` at 200, and `/login/` redirects home, so
re-hydrating the login form fails. Therefore:

1. record the hit;
2. verify with `GET /profile` (200) and read the `zss` cookie (length >= 20);
3. end the chunk (`blocked = true`);
4. re-queue the rest of the chunk on the next session.

Do not spend 60 s on `logout` + `hydrate`; it will fail and truncate the chunk anyway.

## Verdict mapping

| Response | Verdict |
|---|---|
| `{"success": true}` | `success` (hit) |
| `error_fields` contains `password` and text has "incorrect" | `validated` |
| text has "has been closed" | `closed` |
| text has "unable to log you in" | `unable` (risk/captcha; rotate IP) |
| text has "confirm it's really you" or "trouble sending a login link" | `link` |
| HTTP 403 | DataDome; drop the session |
| HTTP 429 | pace; wait or lower `PACE` |
| HTTP 407 | proxy auth/quota; drop the account |

`require_link: true` can appear on a **validated** row. Classification must check
`isInvalid` first; otherwise validated rows are counted as link. This was a real bug in the
upstream worker (see `docs/05-UPSTREAM-GAPS.md`).
