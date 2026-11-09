# Security review 1: credentials, web pages, upload/download links

Target: bbik52/docmost-mcp-remote, commit a5e3624 (v1.2.3). Static review only; no code was executed.
Paths below are relative to the repository root (`src/docmost_mcp_remote/...` abbreviated as `src/...`).
Docmost server behaviour was checked against the Docmost source in /home/user/SEM-docmost.

## Verdicts

| Item | Verdict |
|---|---|
| 1.2 Credential handling | FAIL (finding C-1, Critical) |
| 1.5 Web pages | PASS WITH NOTES |
| 1.7 Upload and download links | PASS WITH NOTES |

The password handling itself (not logged, not stored in `ask` mode, sent only to DOCMOST_URL) and the crypto are sound. Item 1.2 fails because of how the Docmost session token is used after sign-in: the shared HTTP client keeps the last signed-in member's Docmost cookie and Docmost prefers that cookie over the per-member bearer token.

---

## Findings

### C-1 (Critical): shared httpx cookie jar makes every member act as the last person who signed in

Evidence:
- `src/docmost/ce.py:103-109` creates one `httpx.AsyncClient` for the whole server. No `cookies=` policy is set, and nothing in `src/` ever clears `self._http.cookies` (grep for `cookies` in `src/` finds only `ce.py:129,215,244` and the web cookie code).
- `src/docmost/ce.py:127-132`: `login()` POSTs to `auth/login`. Docmost answers with `Set-Cookie: authToken=<JWT>; Path=/; HttpOnly; SameSite=Lax; Secure=<APP_URL is https>` (Docmost `apps/server/src/core/auth/auth.controller.ts:223-229`).
- httpx 0.28.1 (`uv.lock:1007-1008`) stores every response cookie in the client's jar (`_send_single_request` calls `self.cookies.extract_cookies(response)`), and `build_request` merges the jar into every later request. `ce.py:195-198` and `ce.py:159-163` both use `self._http.build_request(...)`, so the jar's `authToken` cookie goes out with every Docmost API call and every download, next to the member's own `Authorization: Bearer` header (`ce.py:193`, `ce.py:158`).
- Docmost's JWT strategy reads the cookie first and the header only as a fallback: `apps/server/src/core/auth/strategies/jwt.strategy.ts:32-33`, `return req.cookies?.authToken || extractBearerTokenFromHeader(req);`.
- The unit-test fake (`tests/fakes.py:60-66`) checks only the Authorization header, and no integration test signs in two members through one `CeDocmostClient` and then checks who Docmost thinks it is. The tests therefore cannot catch this.

Effect: after member A signs in on the web page, A's Docmost JWT sits in the process-wide jar. Each later tool call, resource read, download link and upload "Done" for any member B carries A's cookie, and Docmost authenticates it as A. The member-B bearer token is ignored. This lasts until another member signs in (whose cookie then replaces A's) or until A's JWT expires (Docmost default 90 days). In `stored_password` mode each automatic re-login (`members.py:153`) also replaces the cookie.

Exploit scenario: a regular team member (or any holder of a member's OAuth or personal token) waits until a Docmost workspace admin signs in to the sidecar. From then on the member's MCP calls run with the admin's Docmost rights. They can read private spaces, and with the `admin` MCP scope they can change roles, invite users or deactivate accounts. Docmost records the actions as the admin's. Without any attacker this is still a confidentiality failure: members see each other's private pages, and edits are attributed to the wrong person. `ALLOWED_SPACES` (`tools/spaces.py`) is enforced by this server, but every Docmost permission check runs against the wrong user.

Conditions: the cookie goes out whenever the cookie jar's domain, path and Secure rules match. That covers the default and recommended setup, where DOCMOST_URL is https and points at the same host Docmost sets the cookie for. It also covers http DOCMOST_URL when Docmost's APP_URL is http. The only setup where it stays hidden is DOCMOST_ALLOW_INSECURE_HTTP=true with an http internal DOCMOST_URL while Docmost's APP_URL is https, because the cookie then has the Secure flag and the jar will not send it over http. That setup is fragile.

Status: confirmed by reading the code. Not reproduced at runtime, because this review was static only. The reasoning chain has been checked against the pinned httpx version's documented behaviour and the Docmost source in this repository. A two-user integration test would confirm it in a few minutes.

Suggested fix (upstream or local patch):
1. Stop the jar from persisting anything. One option is a jar whose policy rejects every cookie: `httpx.AsyncClient(cookies=httpx.Cookies(http.cookiejar.CookieJar(policy=http.cookiejar.DefaultCookiePolicy(allowed_domains=[]))))`. Another is to call `self._http.cookies.clear()` right after each send. A third is to read the token from the login response's `Set-Cookie` header using a throwaway client for `auth/login` only.
2. Add a regression test: log in two different users through one `CeDocmostClient`, call `users/me` with each session, and assert each gets its own identity. Also make the fake transport honour a `Cookie: authToken` header the way Docmost does.
3. Do not deploy until this is fixed. If the sidecar has already been running, review Docmost audit and page history for wrongly attributed actions, and rotate the Docmost JWT secret (APP_SECRET) to kill the leaked sessions.

### M-1 (Medium): open dynamic client registration allows consent phishing and attacker-chosen redirects

Evidence: `src/oauth.py:137-143` (registration enabled for anyone), `oauth.py:61-77` (https redirect to any host, or any custom scheme outside a short blocklist), `oauth.py:220-239` (pending request not tied to any member), `web/routes.py:362-384` and `web/templates/consent.html:4-6` (consent shows the client's self-chosen name and the redirect host), `web/routes.py:406-412` (Deny also redirects to the client's URI).

Scenario: an attacker registers a client named "Claude" with `redirect_uris=["https://attacker.example/cb"]`. They start `/authorize` with their own PKCE challenge and send the authorize URL to a staff member. A signed-in member sees "Allow Claude to use Docmost as you?". If they click Allow, the code is delivered to attacker.example. The attacker holds the PKCE verifier, swaps the code for access and refresh tokens, and can use any scope the member ticked, including write, delete and admin. Clicking Deny still sends the browser to the attacker's URI, which makes the server an open redirector with one click. A custom-scheme redirect (for example an OS protocol handler) is also reachable through Deny.

Mitigating factors: the consent page shows the redirect host and warns "Continue only if you started this from that app". Only `read` is pre-ticked. Codes are single use and expire after 5 minutes. This risk is built into MCP's anonymous dynamic client registration and is not a coding bug.

Fix: for a 10-person team, put an allowlist of redirect hosts and schemes in front of `/register` (for example claude.ai, localhost loopback, `cursor://`), or turn registration off and pre-register clients. Show the full redirect URI, not only the host. Consider not redirecting on Deny when the client has never had a grant.

### L-1 (Low): login rate limits are per process and depend on correct proxy configuration

Evidence: `web/routes.py:102-103` (20 per IP per 10 min, 5 per email per 15 min, in memory), `web/routes.py:187-188` (IP from `request.client.host`), `__main__.py:293-297,301-309` (`proxy_headers=True`, `FORWARDED_ALLOW_IPS` defaults to 127.0.0.1), `ratelimit.py:1-5`.

Issues:
- If the reverse proxy runs in another container (for example 172.18.0.x) and FORWARDED_ALLOW_IPS is left at the default, every client shares the proxy's IP. Twenty failed attempts from anyone then lock out sign-in for the whole team for 10 minutes. If FORWARDED_ALLOW_IPS is `*` and the port is reachable directly, clients can spoof X-Forwarded-For and dodge the per-IP limit. The per-email limit still applies.
- The per-email limit lets anyone lock a known staff email out of the sidecar sign-in for 15 minutes with 5 bad attempts. The CSRF token is no obstacle because a GET to `/login` hands one out (`routes.py:200-217`).
- Failed sign-ins are never logged (`members.py:56-57`, `routes.py:238-239`), so brute force goes unseen. The limits also reset on restart.

Fix: set FORWARDED_ALLOW_IPS to the exact proxy address. Add rate limiting or fail2ban at the reverse proxy. Log failed sign-in attempts with IP and a hash of the email, never the password.

### L-2 (Low): web sessions are stateless; plain "Sign out" does not revoke the cookie on the server

Evidence: `web/routes.py:137-159` (signed itsdangerous cookie holding `m`, `c`, `t`, lifetime WEB_SESSION_HOURS, default 12 h), `routes.py:251-257` (logout only deletes the cookie in the browser), `routes.py:259-268` and `routes.py:171-174` (only "Sign out everywhere" moves `web_sessions_after`). `revoke_grant` (`routes.py:328-343`) does not call `_active_member`, so a cookie that was invalidated by "sign out everywhere", or that belongs to a disabled member, can still revoke that member's grants. That action can only destroy access, not gain it.

Fix: have plain logout also set `web_sessions_after`, or keep a server-side session id. Call `_active_member` in `revoke_grant`.

### L-3 (Low): passwords stored earlier survive a switch to RELOGIN_MODE=ask

Evidence: `members.py:115-119`. When lazy key rotation runs on a session that still has `password_ciphertext`, it decrypts the password and saves it again whatever RELOGIN_MODE is. `db/admin_store.py:227-230` (rotate-key) does the same. Only the member's next sign-in clears it (`members.py:89-95`, `db/store.py:129-144`). Startup never purges the column.

Impact for our plan: none if we start in `ask` mode and never switch. It matters only if `stored_password` was ever turned on.

Fix: on startup with RELOGIN_MODE=ask, run `UPDATE docmost_sessions SET password_ciphertext = NULL`. As a deployment check, run `SELECT count(*) FROM docmost_sessions WHERE password_ciphertext IS NOT NULL` and expect 0.

### L-4 (Low): upload and download links are bearer URLs that leave this server

Evidence: `web/downloads.py:40-41,75-101` (download link: AES-GCM blob in the URL path, 10 min, reusable until expiry), `web/uploads.py:314-335` (upload link: `secrets.token_urlsafe(32)`, lifetime UPLOAD_RETENTION_MINUTES, default 60, range 5 to 1440 per `config.py:183-189`). `web/downloads.py:54-63` and `__main__.py:256-263` redact `/downloads/<x>` and `/uploads/<x>` from uvicorn's access log only.

The links are returned in MCP tool results, so they are stored in AI-client transcripts and with the model provider. The upload result also includes a ready-made `curl` command (`uploads.py:334`). Reverse-proxy access logs (Caddy, nginx, Traefik) will record them in full. Anyone holding a download link can fetch the export or attachment as the member for 10 minutes. Anyone holding an upload link can add arbitrary files to that one page as the member until the link expires or is completed.

Fix: turn off or redact `/downloads/` and `/uploads/` paths in the reverse proxy's access log. Keep UPLOAD_RETENTION_MINUTES short.

### I-1 (Info): smaller observations

- Both cookie types are signed with the same itsdangerous signer and no per-cookie salt (`routes.py:93,137-156`). A signed login cookie `{"c":...}` placed in the session-cookie slot fails with a KeyError on `session["m"]` (`routes.py:163`), giving a 500 rather than a clean redirect. It cannot be used to bypass anything. Fix: use a separate salt per cookie.
- The personal-token hint stores `token[:10]` (`db/store.py:196`), which is `dmr_` plus 6 random characters, about 36 of 256 bits. That is acceptable.
- Personal tokens can be set to never expire (`routes.py:41`). Consider removing that option by policy.
- The web pages set no HSTS header. Set it at the reverse proxy.
- `rotate-key` re-encrypts sessions and snapshots but not pending upload files (`db/admin_store.py:214-257`). Keep SECRET_KEY_PREVIOUS for at least UPLOAD_RETENTION_MINUTES after a rotation. The web-cookie signer uses only the current key, so a rotation signs everyone out of the web pages. That is acceptable.
- Signing out of the sidecar neither ends nor drops the member's Docmost JWT. Only `admin revoke-member` drops it. This is by design, and Docmost CE JWTs cannot be revoked early in any case.
- LOG_LEVEL=debug was not assessed for MCP payload logging (FastMCP internals are out of scope). Keep `info`.

---

## 1.2 Credential handling: FAIL

Password path, form to Docmost:
- `web/routes.py:219-239`: the password is read from the form into a local variable. CSRF is checked first, then the rate limits, then `MemberService.sign_in`. The password never reaches a log call, a template, a cookie or the response. On failure the login page is re-rendered with the email only (`routes.py:226-239`, `templates/login.html:10-11`, where the password field has no `value`).
- `members.py:47-98`: the password goes only to `self._docmost.login(email, password)` (`members.py:52`). Exception handlers log `exc`, which carries Docmost's own error message (`docmost/ce.py:79-87,254-273`) and never the request body (`docmost/errors.py:1-5`). Every auth failure uses the same message (`members.py:23,56-57,72-73`). The allowlist is checked after Docmost answers, so neither the response nor its timing reveals whether an email is allowed (`members.py:69-73`).
- `docmost/ce.py:127-132,185-219`: a JSON POST to `{DOCMOST_URL}/api/auth/login` with `follow_redirects=False` (`ce.py:107`). No httpx event hooks exist. The `httpx` logger is set to WARNING (`__main__.py:291`). The base URL is fixed from settings at startup (`server.py:96-102`). The password therefore goes only to the configured DOCMOST_URL and never follows a redirect.
- DOCMOST_URL must be https unless DOCMOST_ALLOW_INSECURE_HTTP=true is set (`config.py:131-134,261-268`). The server logs a warning when http is allowed (`__main__.py:298-299`).
- Uvicorn's access log records only method, path and status, never form bodies (`__main__.py:256-263`). No middleware logs request bodies (`server.py`).

Persistence with RELOGIN_MODE=ask:
- `config.py:204-208`: `relogin_mode: Literal["ask","stored_password"] = "ask"`. Stored-password mode is off by default and any other value fails at startup.
- `members.py:89-95`: in `ask` mode `password_ciphertext` is saved as `None`. `members.py:141-144`: `_relogin` does nothing in `ask` mode. `db/schema.py:64-66`: the column is nullable and documented as stored_password only. See L-3 for passwords left over from earlier.
- In stored_password mode the password is encrypted with the same AES-GCM key, bound to the member id, and replayed to `auth/login` when Docmost returns 401 (`members.py:141-159`). The login page tells the member (`templates/login.html:5`).

crypto.py:
- AES-256-GCM via `cryptography` AESGCM (`crypto.py:17,41-45`). The key comes from HKDF-SHA256 over SECRET_KEY with a fixed salt and a per-purpose `info` string (`crypto.py:30-38`, purpose `stored-credentials-v1`). Cookies use a separate derived key (`web-cookies-v1`, `routes.py:93`). SECRET_KEY must be at least 32 characters (`config.py:113,230-235`); its entropy is not checked, so generate it with `openssl rand -base64 48`.
- Each encryption uses a fresh random 96-bit nonce from `secrets.token_bytes(12)` (`crypto.py:63`). That is safe for this volume, far below the roughly 2^32 messages per key where random-nonce collisions become a concern.
- Associated data: the caller's `context`. Docmost sessions and passwords use the member id (`members.py:88-95,109-111,124,129-134`), so a ciphertext copied into another member's row fails authentication. Snapshots use `snapshot_context(id, member_id)` (`db/admin_store.py:247`). Download links use the constant `download-link` (`downloads.py:42`), with the member and grant inside the authenticated plaintext. The blob format is version byte, 8-byte key id (a truncated SHA-256 of the derived key, which leaks nothing usable), nonce, then ciphertext and tag (`crypto.py:62-84`).
- Rotation: `Cipher` decrypts with the current or the SECRET_KEY_PREVIOUS key (`crypto.py:48-56`). Sessions are re-encrypted lazily on use (`members.py:115-119`) or all at once with `admin rotate-key` (`admin.py:121-134`, `db/admin_store.py:214-257`). This is sound, apart from the notes in L-3 and I-1.
- Issued bearer tokens carry 256 bits of randomness and are stored only as SHA-256 hashes (`crypto.py:91-98`, `db/store.py:169-199`). Comparisons use `hmac.compare_digest` (`crypto.py:101-102`).

Failure reason: C-1. The Docmost JWT is correctly encrypted at rest, but in use it leaks across members through the shared cookie jar.

## 1.5 Web pages: PASS WITH NOTES

- CSRF: every state-changing POST checks a form `csrf` value against a token in the signed, HttpOnly cookie using a constant-time compare:
  - `/login` (`routes.py:224-231`, against the login cookie)
  - `/logout` (`routes.py:255`)
  - `/logout/everywhere` (`routes.py:264`)
  - `/account/tokens` (`routes.py:305-309`)
  - `/account/grants/{id}/revoke` (`routes.py:332-336`)
  - `/oauth/consent` POST (`routes.py:390-394`)

  Upload POST and DELETE endpoints have no CSRF token. They are authorised by the secret in the URL, so a cross-site attacker would need that token anyway (`uploads.py:354-361`).
- Login CSRF is prevented because `/login` POST needs the login cookie the GET set (`routes.py:213,224-225`).
- Session fixation: sign-in always issues a new session cookie with a fresh CSRF token and drops the login cookie (`routes.py:241-248`). An attacker-supplied value cannot survive, because the cookie is signed.
- Cookie flags (`routes.py:94-100,137-146`): HttpOnly, SameSite=Lax, Path=/. Secure and the `__Host-` prefix are applied when PUBLIC_URL is https, and `config.py:218-223` requires https except on localhost. Cookies are signed with itsdangerous `URLSafeTimedSerializer` and an HKDF-derived key, and they expire (login cookie 1 h, session 12 h by default). They are signed, not encrypted; the content is a member UUID, a CSRF token and a timestamp.
- Headers on every rendered page (`routes.py:43-53,126-132`): CSP `default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`, plus no-store, nosniff, X-Frame-Options DENY and Referrer-Policy no-referrer. The upload page uses its own CSP, which adds `script-src 'self'`, `img-src blob:`, `connect-src 'self'` and `form-action 'none'` (`uploads.py:208-218`). Downloads send `sandbox` CSP with nosniff and are served as attachments (`downloads.py:43-48,137-141`). HSTS is missing (I-1).
- Templates: Jinja2 `select_autoescape(default=True)` in both environments (`routes.py:104-107`, `uploads.py:300-303`). No `|safe`, `Markup`, or `autoescape false` anywhere in the templates or the code. `upload.js` has no `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `eval` sinks. The client name is truncated to 100 characters and escaped (`routes.py:379,454`).
- Open redirects:
  - After sign-in: `safe_next` allows only paths that start with `/` and not with `//` or `/\` (`routes.py:62-66`). Starlette's `RedirectResponse` percent-encodes tabs and backslashes in Location, so tricks like `/\t/evil` cannot become protocol-relative. That relies on Starlette's behaviour; it was not tested here.
  - After consent: the return page (`routes.py:441-457`, `templates/return.html:3,7`) sends the browser to `construct_redirect_uri(params.redirect_uri, ...)`. That `redirect_uri` comes from the stored authorization request, which the MCP SDK checked against the client's registered URIs. Registered URIs are limited by `redirect_uri_allowed`: https, loopback http, or a custom scheme other than javascript, data, file, vbscript, about, blob or ftp (`oauth.py:57-77,183-199`).
  - Users of the consent page cannot inject a redirect target. However, anyone can register a client, so an attacker can get a code or a Deny-redirect sent to a URL of their choice once the member clicks (M-1).
  - The authorization code is single use: the request is deleted before the code is issued (`routes.py:396-399`), the code TTL is 5 min (`oauth.py:46`), and a replay revokes the grant (`oauth.py:251-254,273-275`).
- Rate limiting is per IP and per email (`routes.py:102-103,232-235`), with the caveats in L-1.
- Error messages are generic: one sign-in failure message for wrong password, unknown user and email not on the allowlist (`members.py:23,56-73`). Separate messages exist for "disabled on this server", which appears only after a correct password, and for "Docmost unavailable".
- Notes: L-1, L-2, M-1, I-1.

## 1.7 Upload and download links: PASS WITH NOTES

Upload links:
- Entropy: `secrets.token_urlsafe(32)`, 256 bits (`web/uploads.py:314`). Only the SHA-256 hash is stored (`db/upload_store.py:92`).
- TTL: UPLOAD_RETENTION_MINUTES, default 60, range 5 to 1440 (`config.py:183-189`). Expiry is enforced in the lookup (`db/upload_store.py:119-128`). Expired links and their encrypted files are deleted every 60 s (`server.py:54-56,85-93`).
- Single use: links are not strictly single use. Files can be added and removed repeatedly while the link is open. Once Done succeeds the link's state is `done` and further uploads are refused (`uploads.py:402-403,466-469,478`). A failed Done reopens the link (`uploads.py:472-477`).
- Scope binding:
  - The link is bound to the member, the creating grant, one page id and a placement (`uploads.py:315-327`).
  - Revoking the grant kills it (`upload_store.py:123-128`).
  - Creating one requires the `write` scope (`tools/files.py:321-334`).
  - On Done, ALLOWED_SPACES is checked again and the action runs through `members.run`, which enforces disabled and allowlist status (`uploads.py:497-498,551`, `members.py:165-169`).
  - File types a browser would execute are stored as octet-stream (`uploads.py:228-257`), and file names are sanitised (`uploads.py:222-225`).
  - Request size is capped (`uploads.py:404-414`).
- Logging: tokens are redacted from uvicorn's access log (`downloads.py:51-63`, `__main__.py:256-263`). Application logs use `link.id`, not the token (`uploads.py:479-481,557`). See L-4 for proxy logs and AI transcripts.

Download links:
- Token: an AES-256-GCM-sealed JSON payload `{m, g, k, a, x}` in the URL. It cannot be forged without SECRET_KEY, and each one has a fresh random nonce (`downloads.py:75-88`).
- TTL is 600 s (`downloads.py:41,96`). Links are not single use and can be reused until they expire.
- Scope binding: member, grant (checked active on every use, `downloads.py:98-100`), kind and arguments. Creating one needs the `read` scope (`tools/files.py:133-272`). Each use runs as the member through `members.run`.
- Responses are served as attachments with `sandbox` CSP and no-store (`downloads.py:43-48,137-148`).
- Logging is the same as for upload links (L-4).

Note: because of C-1, the Docmost requests behind both kinds of link also run as the last member who signed in, not as the link's member.

## Orchestrator verification of C-1 (2026-11-09)

Reproduced with httpx (default AsyncClient, as in ce.py:103) against a local HTTP stub (scratchpad/cookietest.py):
- Login response sets `authToken` without `Secure`: the next request, sent with `Authorization: Bearer USER_B`, also carries `Cookie: authToken=USER_A`. Docmost's JwtStrategy reads the cookie first (apps/server/src/core/auth/strategies/jwt.strategy.ts:33), so the request runs as user A.
- Login response sets `authToken` with `Secure` while the client talks plain http: the cookie is not sent.

Docmost sets `secure: isHttps()` from APP_URL (auth.controller.ts:228). Consequences:
- DOCMOST_URL=https://... (the upstream README's setup): the bug is active. Critical.
- Our planned setup (APP_URL https, DOCMOST_URL=http://docmost:3000 inside Docker): the cookie is stored but not sent. Safe by accident only.
Patch required in our fork before deployment regardless.
