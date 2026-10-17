# ADR 0004: Web UI foundation (htmx + Gleam HTML)

Status: accepted
Date: 2026-10-13

## Decisions

- **HTML rendering:** Lustre 5.7 (MIT) is used only for server-side
  rendering (`element.to_document_string`). It escapes text and attribute
  values, including textarea content; this is verified by tests. It emits
  attributes in sorted order. Lustre's client runtime is not used.
- **htmx:** 2.0.11 (0BSD), vendored at
  `clients/web/static/js/htmx-2.0.11.min.js`. The npm `dist.integrity`
  (`sha512-Thx/Wtpe…dtamA==`) was verified when vendoring; the file's
  SHA-256 is `d6fdc75f…b4000f717`. htmx is configured by its meta tag:
  - `allowEval:false`, `allowScriptTags:false`;
  - `includeIndicatorStyles:false`;
  - `historyCacheSize:0` with `refreshOnHistoryMiss`;
  - `selfRequestsOnly`;
  - explicit `responseHandling`: 4xx fragments (validation, 409 and 412
    conflicts) are swapped so errors are never dropped, and 401 is never
    swapped.
- **Package layout:** `server/packages/web` holds the views, handlers,
  sessions and OIDC. The API router sends every path outside
  `/v1`, `/internal`, `/img`, `/healthz` and `/readyz` to it. Handlers call
  domain operations directly. Where the domain already produces the stable
  JSON contract (search, usage, page detail), the views decode it rather
  than duplicating queries.
- **Sign-in:** the OIDC Authorization Code flow with PKCE (S256), state and
  nonce, stored in a signed, host-only, 10-minute `__Host-libarrie_oidc`
  cookie.
  - `SECRET_KEY_BASE` must be at least 64 characters (Wisp's minimum) and
    is required in hosted mode.
  - Endpoints come from configuration or `.well-known` discovery.
  - The issuer's signing keys (`OIDC_JWKS_URL`) are fetched at startup and
    cached. A token naming an unknown key ID triggers one re-fetch in the
    background, rate-limited to once a minute (the first after startup is
    always allowed), so rotated keys are picked up without a restart and
    forged key IDs cannot make the server hammer the issuer. A failed
    re-fetch keeps the previous keys.
  - `?reauth=1` sends `prompt=login&max_age=0`.
- **Development issuer:** `/dev-issuer/*`, enabled only by
  `DEV_ISSUER_SECRET` outside hosted mode. Its codes are HS256-signed,
  expire after 60 seconds, and bind the client, redirect URI, nonce and
  PKCE challenge. It makes the full browser flow real in development and
  tests.
- **Sessions:** `__Host-libarrie_session` (Secure, HttpOnly, SameSite=Lax,
  seven days); only a hash is stored.
- **Cookies on plain HTTP:** Safari and other WebKit browsers reject
  `Secure` and `__Host-` cookies on `http://localhost`, which broke sign-in
  in local development. On a plain-HTTP web origin, cookies are therefore
  named without the prefix (`libarrie_session`, `libarrie_oidc`) and set
  without `Secure`, and only that form is read
  (`libarrie/web/cookies.gleam`). Hosted mode requires an `https://`
  `WEB_ORIGIN`, so deployments always use the prefixed, Secure form. CSRF is checked by header
  (htmx `hx-headers` on `<body>`, and the upload module) or by form field,
  together with the Origin check. `/v1` cookie authentication now uses the
  same session module.
- **Security headers:** every HTML response carries the strict CSP from
  section 13, with the object-store origin in `img-src` and `connect-src`,
  plus `nosniff`, `Referrer-Policy: same-origin`, HSTS in hosted mode and
  `Cache-Control: private, no-store`.
- **Page markup:**
  - No inline scripts, `style` attributes or `hx-on*`.
  - User text renders inside `hx-disable` containers.
  - Authenticated pages carry `hx-history="false"`.
  - Navigable routes return a full document, or a fragment for htmx
    requests (`Vary: HX-Request`).
  - Unauthenticated htmx requests get 401 with `HX-Redirect` to a validated
    same-origin return path.
- **Theme:** a `libarrie_theme` cookie is rendered as `<html data-theme>`
  before first paint. CSS custom properties hold the section 3 tokens, and
  `prefers-color-scheme` applies for System. Scans are never filtered or
  recolored.
- **Browser upload module** (`upload.js`):
  - converts HEIC to JPEG only via the browser's own decoder;
  - computes SHA-256 with WebCrypto, plus MD5 (`md5.js`, verified against
    RFC 1321 vectors) when the store needs Content-MD5;
  - calls `/v1` with the cookie and CSRF header, PUTs to the presigned URL
    with progress, and completes;
  - remembers operation IDs to recover status after a refresh;
  - asks once per batch about deferred processing.
- **Page images:** without a derived preview (no decoder, or before the
  derive job finishes), page detail shows the original through
  `/pages/{id}/original`. That route authorizes the request, then
  303-redirects to a five-minute signed URL, as section 6 allows for
  originals.

## Tests

- **Server** (`apps/api/test/web_test.gleam`, 10 tests):
  - OIDC sign-in end to end through the development issuer, and state
    rejection;
  - redirect versus `HX-Redirect`, and refusal of open redirects;
  - CSRF and Origin rejection;
  - inert hostile notebook names and transcripts;
  - fragment versus full page, CSP and headers;
  - theme rendering;
  - transcript conflicts preserving unsaved text;
  - search `<mark>`;
  - `/v1` with the browser session;
  - logout revocation and static assets.
- **Browser** (`clients/web`, Playwright 1.64 with the installed Chrome),
  with zero CSP violations and console errors:
  - sign-in, notebook creation, a real upload (hash, presigned PUT,
    completion) and worker processing;
  - transcript correction, search highlights and dark-theme persistence;
  - session expiry during htmx;
  - the skip link.

## Management screens (added later)

- **Notebooks:** create and edit with a description and an identifying
  color, rename, and move to trash. Colors come from a fixed palette rendered
  with CSS attribute selectors, because the CSP forbids inline styles. A
  color set by another client outside the palette is kept but not shown.
  An empty `color` now clears it, in both the API and the contract.
- **Renumbering:** `/notebooks/{id}/renumber` shifts a range of page numbers
  atomically, guarded by the numbering revision. Page detail can change one
  page's number or move it to another notebook, guarded by its version.
- **Page detail:**
  - Rescan: the operation ID is minted when the form renders, so a double
    submission is one rescan.
  - Replacement upload: `upload.js` sends `page_id` instead of a notebook
    and number, always for immediate processing, then reloads the page.
- **Deferred processing:** the Usage page counts pages waiting for
  processing, and "Process now" admits up to 100 per click.
- **Exports:** `/exports` requests an export of all or selected notebooks,
  optionally with trash. The list polls only while an export is preparing.
  Each part downloads through an authorized 303 to a five-minute signed URL.
- **Permanent deletion:** every purge (one page, one notebook, or the whole
  trash) goes through a confirmation page.
- **Account:** `/account` shows the account's status and links to exports.
  Deleting the account needs an explicit confirmation. A scheduled deletion
  can be cancelled until it takes effect, and coverage-end acknowledgement
  is asked for only when the server requires it.
- **Recent sign-in:** purge, account deletion and cancellation require a
  sign-in within the last five minutes. The server checks this on every
  submission, not only when rendering. An older sign-in gets a "Sign in
  again" link to `/auth/login?reauth=1` (`prompt=login`, `max_age=0`) that
  returns to the same screen.
- **Messages after redirects:** confirmations use `?done=<code>` with a fixed
  set of codes, so request text is never echoed into the page.
- **Tests:**
  - `apps/api/test/web_management_test.gleam` (8 tests) covers conflicts,
    stale versions, collisions, double submissions, the recent-sign-in rule
    on form and submit, journal-pending purges and grace-period read-only
    access.
  - `clients/web/tests/management.spec.ts` covers renumbering, replacement
    upload, export download and account deletion in the browser.

## Not yet built

- **Upload recovery:** done (ADR 0008).
- **Accessibility:** automated audit done for static screens (ADR 0008);
  interactive states are not yet audited.
