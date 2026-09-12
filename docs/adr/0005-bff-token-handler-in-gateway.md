# ADR-0005: BFF Token-Handler in the Gateway for SPA Auth

**Status:** Accepted
**Date:** 2026-09-10
**Author:** Pulith Thewmika

## Context

M2 shipped the SPA and the gateway as two halves that were never joined. The
Playwright suite proved the SPA against `page.route()` mocks; k6 proved the
gateway and backend with hand-rolled JWTs. Nothing exercised the real browser
against the real gateway, and when I finally wired them together four things
were broken at once (STAM-440):

1. The Vite dev proxy sent `/api` to `:8080` — Kafka UI in compose — not the
   gateway on `:8085`.
2. `src/auth/config.ts` defaulted its auth endpoints to
   `/api/v1/oauth2/{authorize,token,refresh,logout}`. Nothing served them.
3. The gateway had no route that could match those paths.
4. The frontend was not in `docker-compose.yml` at all, so the edge could not
   be exercised anywhere in the dev stack.

Fixing the plumbing forced a design question that had been dodged since M2. The
security baseline (CLAUDE.md §16) says: *access tokens live in browser memory,
refresh tokens live in an httpOnly cookie.* The SPA's `AuthContext` and
`authFetch` are written for exactly that — they call `refresh` and `logout` with
`credentials: "include"` and no body, expecting the server to read a cookie and
return only an access token.

But **STAM-identity cannot do that.** It is a stock Spring Authorization Server
with a custom public-client refresh grant. Its `/oauth2/token` endpoint returns
*both* the access token and the refresh token in the JSON response body, to
whoever calls it. There is no cookie anywhere in identity, no `/oauth2/refresh`,
no `/oauth2/logout`. A browser talking to it directly would have to hold the
refresh token itself — in memory (lost on every reload) or in storage (§16
forbids it, and it is the exact XSS exfiltration target the httpOnly cookie
exists to remove).

The realistic options:

1. **SPA talks to the Authorization Server directly.** Correct the paths
   (`token` and `refresh` both to `/oauth2/token`, `logout` to
   `/connect/logout`), and accept that the refresh token now lives in the
   browser. This contradicts §16 and means a page reload logs the user out,
   because a memory-only refresh token does not survive it. Rejected: it trades
   away the security property §16 was written to guarantee, for less code.

2. **Full BFF — no tokens in the browser at all** (STAM-77). The gateway becomes
   a confidential OAuth client, holds the access *and* refresh tokens in a
   server-side session store (Redis), hands the SPA an opaque session cookie,
   and swaps that cookie for a JWT on every downstream call. This is a strictly
   stronger posture, but it is a different system: the SPA loses its entire
   PKCE/token module, the gateway becomes stateful with respect to user
   sessions, and §16 has to be rewritten. It is tracked as its own stretch task
   and is out of scope for closing STAM-440.

3. **BFF token-handler in the gateway.** The SPA stays a public client and keeps
   doing client-side PKCE and holding its access token in memory — unchanged.
   The gateway owns only the token-exchange leg: it proxies the authorization
   code exchange and the refresh to identity, strips the refresh token out of
   the response, and keeps it in an httpOnly cookie scoped to the auth
   endpoints. The SPA sees only `{ access_token, expires_in }`.

## Decision

We implement option 3. A `BffAuthController` in `STAM-gateway` exposes three
endpoints, all under `/api/v1/oauth2/` and all `permitAll` at the gateway
security layer because they run before the SPA has a token:

- **`POST /api/v1/oauth2/token`** — forwards the SPA's authorization-code
  exchange (form body: `grant_type`, `code`, `redirect_uri`, `client_id`,
  `code_verifier`) to identity's `/oauth2/token`. Takes the `refresh_token` out
  of identity's JSON response, sets it as
  `Set-Cookie: stampede_rt=<token>; HttpOnly; SameSite=Lax; Path=/api/v1/oauth2`
  (plus `Secure` when `bff.cookie.secure=true`, which is the default everywhere
  except local dev over plain http), and returns
  `{ access_token, expires_in, token_type }` to the browser.

- **`POST /api/v1/oauth2/refresh`** — reads the `stampede_rt` cookie, calls
  identity's `/oauth2/token` with `grant_type=refresh_token`, rotates the cookie
  to the new refresh token identity issues (identity has
  `reuseRefreshTokens=false`, so every refresh returns a fresh token and a
  replayed one revokes the family), and returns `{ access_token }`. If the
  cookie is missing or identity rejects it, the cookie is cleared and the
  response is 401.

- **`POST /api/v1/oauth2/logout`** — clears the cookie and returns 204. It does
  not need to call identity: the refresh family self-destructs on the next reuse
  attempt, and dropping the cookie is the meaningful client-side action.

The **authorize** step is *not* a BFF concern — it is a top-level browser
navigation carrying PKCE parameters the SPA generated. `authorizeUrl` in the SPA
points at `/oauth2/authorize`, which the gateway already routes to identity. The
gateway also already routes `/login` and `/.well-known/**` there, so the whole
interactive login (authorize → login form → redirect back with `code`) works
through the gateway origin. The Vite dev proxy and the compose `nginx.conf` are
updated to forward `/oauth2`, `/login`, and `/.well-known` alongside `/api`.

The gateway does not become stateful: it stores nothing. The refresh token
lives only in the client's cookie; the gateway reads it, forwards it, and
forgets it.

### Implementation notes — what live verification actually surfaced

The BFF endpoints themselves worked on the first pass (`BffAuthIT` against a
WireMock identity). Driving the *interactive* login through the real stack
(`e2e/real/journey.spec.ts`, no mocks) surfaced three more defects in the
request path around it, none of them about the BFF's own logic:

- **Identity's redirects resolved to its compose-internal hostname.**
  `LoginUrlAuthenticationEntryPoint` and the post-login `SavedRequest` bounce
  both build absolute URLs from the Host the request arrived with. Spring
  Cloud Gateway's `NettyRoutingFilter` rewrites Host to the proxied target by
  default, so identity saw `identity:8080` — not resolvable by a browser.
  Fixed with the `PreserveHostHeader` route filter on the identity route (keeps
  the Host the gateway itself received) plus `server.forward-headers-strategy:
  framework` on identity (belt-and-braces, needed if a future hop adds a real
  reverse proxy in front that only sets `X-Forwarded-*`).
- **The gateway's CORS config was blanket (`/**`).** It matched `/login` and
  `/oauth2/authorize` — pure browser navigations, never fetch/XHR — and
  Spring's `CorsWebFilter` rejects any `Origin` it doesn't recognize outright.
  Chromium sends the literal `Origin: null` on a same-origin POST navigation
  when the page was served with `Referrer-Policy: no-referrer` (identity's
  Spring Security default), which turned the login form submit into a 403
  with no relation to a real cross-origin request. Scoped CORS to `/api/v1/**`
  — the actual fetch/XHR surface — where it belongs.
- **The SPA never requested `offline_access`.** Without it identity issues an
  access token only; the BFF had nothing to put in the refresh cookie. One
  scope value, `src/auth/config.ts`.

None of these are BFF design questions — they're the ordinary cost of a
reverse proxy sitting in front of a plain Spring Security app that was never
built with one in mind. Recorded here because they'd otherwise look like
unrelated, unexplained one-line diffs scattered across three repos.

## Consequences

**Positive:**

- The refresh token is never reachable from JavaScript. §16 holds as written —
  no amendment, no `localStorage`.
- Session survives a page reload: `AuthContext` calls `refresh` on mount, the
  cookie is sent automatically, and the user is back without re-authenticating.
- The SPA's auth module is unchanged in shape — client-side PKCE, access token
  in memory, the same three endpoints it already calls. Only the `authorizeUrl`
  default moves.
- Refresh-token rotation and reuse detection continue to work exactly as
  identity implements them; the gateway is a transparent relay for that grant.
- No new infrastructure. No Redis session store, no new repo, no new compose
  service beyond the frontend itself.

**Negative:**

- The gateway now has knowledge of the OAuth token response shape. If identity
  changes the token endpoint's contract, `BffAuthController` has to change with
  it. This coupling is the price of stripping the refresh token server-side.
- The cookie is `SameSite=Lax`, not `Strict`, because the OAuth redirect back
  from identity is a top-level cross-site navigation and `Strict` would drop the
  cookie on the callback. `Lax` plus the cookie only being useful to mint a new
  access token (every real API call still needs the `Authorization: Bearer`
  header the SPA sets itself) keeps the CSRF surface small, but it is not zero —
  a follow-up could add a double-submit token on `/refresh`.
- This is a token-handler, not the full "no tokens in browser" BFF. The access
  token still sits in browser memory and an XSS payload could read it for its
  ~10-minute lifetime. STAM-77 remains the way to close that gap and is now
  explicitly a separate decision, not something to sleepwalk into.

**When the full BFF (STAM-77) would win:** if we ever need to support truly
untrusted SPA hosting, or the threat model puts a 10-minute access-token
exposure over the line, the confidential-client + Redis-session design is the
answer. It costs the SPA's PKCE module and a stateful gateway; we are not paying
that now.
