# Security Review: docmost-mcp-remote (Phase 1)

Date: 2026-11-09. Scope: `bbik52/docmost-mcp-remote` at commit `a5e3624` (v1.2.3), which is also the base of our fork `osh-labs/docmost-mcp-remote`. Method: static code review in three parts, a dependency audit and the project's unit test suite. The server was not run against a live Docmost, and the integration tests were not run because no Docker daemon was available.

Detailed reports, with file:line evidence:

- [01-credentials-web-links.md](security-review/01-credentials-web-links.md) covers items 1.2, 1.5 and 1.7.
- [02-oauth-authz-egress.md](security-review/02-oauth-authz-egress.md) covers items 1.3, 1.4 and 1.6.
- [03-dependencies-tests.md](security-review/03-dependencies-tests.md) covers items 1.1 and 1.8.

In those reports, file:line references point into the upstream source tree at `a5e3624`. `<scratch>` stands for the session's temporary working directory.

## 1. Verdict

Go, with conditions. Adopt the fork once patches P-1 and P-2 are merged into the commit we build our image from. Do not deploy the upstream image unmodified.

## 2. Checklist results

| Item | Area | Result |
|---|---|---|
| 1.1 | Dependency audit | PASS. pip-audit (PyPI and OSV) found no known vulnerabilities in the 84 locked runtime packages |
| 1.2 | Credential handling | FAIL before patch (C-1). Password handling and encryption themselves pass: the password is used once, AES-256-GCM, per-purpose keys, ciphertext bound to the member, rotation supported |
| 1.3 | OAuth 2.1 | PASS WITH NOTES (M-1). Exact redirect match, S256 PKCE only, single-use 5-minute codes, resource bound on every request, rotated refresh tokens with reuse detection |
| 1.4 | Outbound network | PASS. Only `DOCMOST_URL`, with redirects off; no telemetry, no update checks, no fetching of client- or page-supplied URLs |
| 1.5 | Web pages | PASS WITH NOTES. CSRF on all POSTs, `__Host-` signed cookies, strict CSP, path-only `next`, autoescaped templates |
| 1.6 | Authorization | PASS WITH NOTES. Every Docmost call uses the member's own token; scopes enforced when a tool runs; `ALLOWED_SPACES` checked against the page's actual space |
| 1.7 | Upload and download links | PASS WITH NOTES. 256-bit tokens, short TTLs, bound to the grant; they are bearer URLs |
| 1.8 | Tests | PASS. 363 unit tests passed against Postgres 16; ruff and mypy strict are clean. The 29 integration tests were not run |

## 3. Findings and disposition

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| C-1 | Critical | The shared httpx client stores the `authToken` cookie that Docmost sets at login and sends it on later requests. Docmost's `JwtStrategy` reads the cookie before the Bearer header (`apps/server/src/core/auth/strategies/jwt.strategy.ts:33`), so every member acts as the last person who signed in. We reproduced the leak with httpx against a local stub. The cookie is sent when it lacks `Secure` or when `DOCMOST_URL` is https | P-1: the client never stores or sends cookies, plus a regression test. Our layout (`APP_URL` https, internal `DOCMOST_URL` http) avoids the leak only by accident, so the patch is still required |
| M-1 | Medium | Open Dynamic Client Registration accepts any https redirect and any client name. An attacker can register a client named "Claude" and phish a member into approving it on the consent page | P-2: `OAUTH_REDIRECT_ALLOWLIST` setting (Claude callbacks plus loopback); refuse redirect URIs that contain userinfo |
| L-1 | Low | Login and registration rate limits are per IP and depend on `FORWARDED_ALLOW_IPS`; failed sign-ins are not logged | Mitigated: `deploy/compose.yaml` sets `FORWARDED_ALLOW_IPS` to the fixed proxy subnet. Add fail2ban on Caddy logs (Phase 4.6) |
| L-2 | Low | Plain sign-out does not revoke the web session on the server; "Sign out everywhere" does | Accept. Document it for members |
| L-3 | Low | Passwords stored under `RELOGIN_MODE=stored_password` survive a switch to `ask` | Not applicable: we start with `ask` and never store passwords |
| L-4 | Low | Download and upload links are bearer URLs and appear in AI transcripts and proxy logs | Mitigated in part: the Caddy access-log filter redacts them (`deploy/Caddyfile`). Accept the transcript exposure: links last 10 to 60 minutes |
| L-5 | Low | `/authorize` has no rate limit | Accept for now; covered by Caddy and fail2ban |
| L-6 | Low | Personal tokens can be created with no expiry | Policy: members use the default of 90 days. Possible later patch |

## 3a. Patch status

| Patch | Commit in `osh-labs/docmost-mcp-remote`, branch `osh/security-patches` | Tests |
|---|---|---|
| P-1 (C-1) | `48e517c`: the shared client's cookie jar never stores or returns a cookie; a request hook strips any `Cookie` header | New regression tests fail on the old code and pass on the new |
| P-2 (M-1, L-1) | `b5f5e94`: `OAUTH_REDIRECT_ALLOWLIST` is enforced at `/register` and again at `/authorize`; `user@host` redirect URIs are always refused | Unit tests for allowed, refused, loopback, userinfo and unset cases |

Full suite on the patched branch: 386 unit tests passed; ruff and mypy are clean. Not yet merged to the fork's `master`, and no image has been built yet.

Note: while `OAUTH_REDIRECT_ALLOWLIST` is set, private-scheme redirects such as `cursor://` are refused unless they are listed. Claude.ai, Claude mobile and Claude Code (loopback) are unaffected.

## 4. Conditions before production

1. P-1 and P-2 are merged in the fork, their unit tests pass, and the image is built from that commit and referenced by digest in `MCP_IMAGE`.
2. `OAUTH_REDIRECT_ALLOWLIST=https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback` is set in `deploy/.env`.
3. Phase 3 test T-02 (permission isolation) is extended so that two members are signed in at the same time and each sees only their own spaces. This is the live check for C-1.
4. The integration test suite is run once against the pinned Docmost tag in a Docker-capable environment.

## 5. Memory note

Importing the server package peaks at about 113 MiB RSS, a lower bound for a running server. The sidecar's `mem_limit` of 192m in `deploy/compose.yaml` leaves little headroom. Measure at T-10 and raise it to 256m if needed.

## 6. Sign-off

| Role | Name | Date | Decision |
|---|---|---|---|
| Owner | Chris Lee | | |
