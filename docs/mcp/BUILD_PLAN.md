# Docmost Community + Remote MCP: Build Plan

Prepared 2026-11-09 for the project owner. Follows the handoff notes of the same date. Audience: the coding agent and the reviewer working in `osh-labs/SEM-docmost`.

Status of this document: planning only. Nothing below has been deployed or executed against a running Docmost. Statements marked "verified in source" were checked in this repository at `863352b` (Docmost 0.97.0). Statements attributed to third-party repositories are what those repositories document, not our own test results.

---

## 1. Bottom line

1. A GitHub search found about 30 public MCP servers for Docmost Community Edition. One of them, `bbik52/docmost-mcp-remote` (Apache-2.0, Python, first commit 2026-10-25, v1.2.3), already implements almost exactly the design in handoff section 7:
   - remote Streamable HTTP
   - OAuth 2.1 with Dynamic Client Registration
   - per-user Docmost login, with the Docmost token stored encrypted
   - personal bearer tokens for Claude Code
   - scopes (`read` by default; `write`, `delete` and `admin` are opt-in)
   - audit log, rate limits, output caps
   - snapshots before writes, and no permanent delete

   Its README states it is tested in CI against Docmost 0.80.1 to 0.97.

   A second remote candidate, `Rahulk644/docmost-mcp` (MIT, Rust), also has per-user OAuth 2.1, but keeps grants in memory only (section 4.1).
2. Recommendation: do not write a new MCP server first. Fork `bbik52/docmost-mcp-remote` into `osh-labs`, review it for security, build our own image from a pinned commit, and run it as a sidecar (handoff option A). Write our own TypeScript server (Track C, section 7) only if the review or the acceptance tests fail.
3. Docmost itself does not need code changes. Run the upstream `docmost/docmost` image at a pinned tag. Because Docmost is not modified, the AGPL section 13 source-offer obligation in handoff section 4 does not apply. This fork then holds deployment config, docs and, if we adopt it, the MCP sidecar source.
4. The survey resolves most of the unverified items in handoff section 8 (see section 3). The items still open are live-edit behavior, memory on 1 GB, and tests against our own data.
5. Estimated effort (agent-hours, assumption): Track A/B, about 3 to 5 working days to production, most of it review, deployment and testing. Track C, about 3 to 5 weeks to reach the same feature level and hardening.

---

## 2. GitHub prior-art survey

Search run 2026-11-09 with the GitHub repository search API (`docmost mcp`, `docmost-mcp`, `docmost oauth mcp`, `docmost streamable http`, `docmost yjs`, `docmost cli`, `docmost sdk`). We cloned the 13 most relevant repositories and read their documentation. Star counts are small across the board (34 or fewer), so popularity tells us little about quality.

### 2.1 Candidates

| Repository | Lang / license | Last commit | Transport and auth | Relevance |
|---|---|---|---|---|
| `bbik52/docmost-mcp-remote` | Python / Apache-2.0 | 2026-10-27 | Streamable HTTP; OAuth 2.1 + DCR + PKCE; per-user Docmost login; personal bearer tokens | Direct match to our design. 62 tools, Postgres state, ADRs, threat model, CI against real Docmost |
| `abelsr/docmost-mcp-oss` | Python / MIT | 2026-09-24 | stdio or HTTP; single account | Writes the body through the Yjs collaboration WebSocket. bbik52 used it as its reference and later dropped the Yjs path |
| `Rahulk644/docmost-mcp` (fork of wisflux) | Rust / MIT | 2026-11-06 | Streamable HTTP; per-user OAuth 2.1 + DCR + PKCE that reuses the Docmost login session; static break-glass bearer; grants in memory only | Second remote candidate (section 4). Lower memory than Python; users must reconnect after every restart |
| `YugenLabsTI/shrd-docmost-mcp` | Python / Apache-2.0 | 2026-11-06 | stdio, shared account | Best API reference: `docs/docmost-api-v0.96.0.md` cites Docmost source lines throughout |
| `wisflux/docmost-local-mcp` | Rust / MIT | 2026-07-12 | Local | Community Edition read and write |
| `mauriciosoares01/docmost-mcp` | TypeScript / MIT | 2026-10-08 | Local | Says it delegates authorization to Docmost RBAC |
| `dilruwanm/docmost-community-mcp`, `punyamsingh/docmost-mcp`, `MrMartiniMo/docmost-mcp` | TypeScript / MIT | 2026-02 to 2026-10 | stdio, shared account | TypeScript references if we go to Track C |
| `ggpo1/docmost-sdk` | multi / no LICENSE file | 2026-05-21 | n/a | Says it builds SDKs from an OpenAPI 3.1 spec of the Docmost API (see 2.2) |
| `glinhard/docmost-cli` | Python / AGPL-3.0 | 2026-07-28 | CLI, shared account | Same license as this fork; `SPECIFICATION.md` documents the server-side collab write path |
| `HaruHunab1320/docmost-mcp` | TS / AGPL-3.0 | 2026-01-01 | Renamed Docmost fork with in-server MCP | Do not use: writes `content` straight to the DB row and bypasses Yjs (`apps/server/src/integrations/mcp/handlers/page.handler.ts:513-522`) |
| `NeerdOnerT/docmost-mcp` | Python / MIT | 2026-08-21 | stdio, shared account | Minimal; sends `pages/update` without `operation`, which may fail |

### 2.2 Notes from the other repositories

Write path. Repositories are split three ways:

| Approach | Used by | Assessment |
|---|---|---|
| `pages/update` with `format: "markdown"`, applied by Docmost through its collab gateway | bbik52, dilruwanm, punyamsingh, glinhard, YugenLabsTI | Simplest. Correct on Docmost 0.70 and later (verified in source, section 3) |
| `pages/update` with ProseMirror JSON from a client-side converter | wisflux, Rahulk644, mauriciosoares01 | Keeps more formatting but needs a converter to maintain. mauriciosoares01 merges append and prepend on the client and always sends `replace`, because the server would otherwise merge a second time and duplicate content |
| Direct Yjs over the `/collab` WebSocket | abelsr, MrMartiniMo | Workaround from before 0.70. abelsr creates a temporary page through `/pages/import` to convert Markdown, and the deleted temporary pages pile up in Trash. MrMartiniMo converts with StarterKit only, so Docmost-specific nodes are lost |

Decision: use the server-side Markdown path, with JSON `replace` only for restores. No WebSocket client.

Write-safety patterns worth keeping, whichever track we take:

- Read back after every write and fail if the body did not change. dilruwanm, bbik52 and Rahulk644 do this.
- Stale-page check: refuse a write if `updatedAt` changed since the agent read the page (YugenLabsTI `STALE_PAGE`). There is no ETag or compare-and-swap in Docmost.
- Busy window: refuse `replace` if another user saved recently (YugenLabsTI `PAGE_BUSY`, bbik52 60 s).
- Per-write confirmation: MCP elicitation (mauriciosoares01, bbik52) or a `confirm: true` argument (Rahulk644).
- Mentions: Markdown that contains mentions triggers Docmost notifications. YugenLabsTI refuses new mentions in edits. Decide a policy (section 11, D-7).

Additional API facts. These come from YugenLabsTI `docs/docmost-api-v0.96.0.md` and glinhard, and we have not tested them:

- Paginate on the cursor, never on item count. A page can return fewer items than `limit` while `hasNextPage` is still true.
- `search` uses offset paging, default limit 25 with no maximum. Its `highlight` field is raw Postgres `ts_headline` output with `<b>` tags and is not HTML-escaped, so sanitize it before returning it to the model.
- The JWT arrives only as a cookie. If both a cookie and a Bearer header are sent, the cookie takes precedence, so the client must not keep a cookie jar. bbik52 and YugenLabsTI already behave this way.
- `POST /api/auth/collab-token` exists and is exempt from the login throttle. It is only needed for direct Yjs access.
- Comments created through REST are page-level. Inline comments anchored to text need a Yjs anchor that the REST API cannot create.
- `POST /api/pages/import` (multipart `.md`) creates a page from a file. It takes no `parentPageId`.

On the abelsr claim that REST ignores `content`: the survey matches it to an older Docmost build, but abelsr never states the version. wisflux and Rahulk644 gate REST body writes on version 0.70 or later.

### 2.3 Why bbik52 is the lead candidate

| Requirement (handoff) | bbik52 status (documented) |
|---|---|
| Public HTTPS, Streamable HTTP at `/mcp` | Yes; must be served at the root of its own host name, not a sub-path |
| OAuth 2.1 + DCR for Claude.ai and mobile | Yes; exact redirect match, PKCE required, RFC 8707 resource binding, refresh rotation, DCR abuse limits |
| Per-user identity through Docmost login, token encrypted at rest | Yes; password not stored by default (`RELOGIN_MODE=ask`) |
| Static bearer for Claude Code | Yes; hashed, shown once, revocable, 7 to 365 day expiry |
| Output caps, `query` limits | `MAX_PAGE_CHARS` (default 60000), list limits, `TOOL_CALLS_PER_MINUTE` |
| Audit log without content | Yes; `audit_log` table and `admin audit` CLI |
| Fail closed on expired or revoked tokens | Docmost answers 401; the server requires the member to sign in again |
| Write safety | Read-back after every write; snapshot before every write; `replace` refused when another user saved in the last 60 s; Trash only |
| Prompt-injection mitigation | Page content wrapped and labelled untrusted; titles stripped of control and bidi characters |

Gaps against our needs:

- Project age. The first commit was 16 days ago, there is one maintainer and 1 star, with 5 open issues. Its long-term upkeep is unknown, which is why we fork it.
- Python. The handoff assumed TypeScript. The language does not matter for a sidecar, but we would maintain Python.
- It ships its own Postgres container. On 1 GB we point it at Docmost's Postgres instead, with its own database and role (section 5.3).
- It supports DCR, not Client ID Metadata Documents (CIMD). Claude supports both (section 10), so this is acceptable.
- Resolving comments needs an Enterprise license in Docmost (Docmost answers `403 This feature requires a valid license`). This cannot be fixed in the sidecar.

---

## 3. Handoff section 8, unverified items: status after the survey

| # | Item | Status | Basis |
|---|---|---|---|
| 1 | REST `pages/update` while the page is open in the editor | Partly resolved. Verified in source: `PageService.updatePageContent` converts the content to ProseMirror and calls `collaborationGateway.handleYjsEvent('updatePageContent', 'page.<id>', ...)` (`apps/server/src/core/page/services/page.service.ts:398-412`), so the write goes into the live Yjs document, not the database row. `append` and `prepend` merge. bbik52 documents that `replace` drops the whole fragment, removes comment marks, and can discard concurrent typing. Still to test: behavior with two live editors (T-04) | Source + bbik52 `docs/DESIGN.md` |
| 1a | Silent no-op | New risk. With `COLLAB_DISABLE_REDIS=true` the gateway has no Redis sync and `handleYjsEvent` returns without doing anything (`collaboration.gateway.ts:146-157`, `this.redisSync?.`), while the endpoint still answers 200. Keep the default (`false`). Every write is read back | Verified in source |
| 1b | Conflicting claim | `abelsr/docmost-mcp-oss` says REST ignores `content`. That was true before Docmost 0.70.0. bbik52 places the change at commit `18b57815` (2026-02-12). Confirm on our pinned tag (T-03) | Third-party docs |
| 2 | Markdown fidelity | Resolved on paper. On 0.97, kept: paragraphs, headings, lists, task lists, quotes, code with language, callouts, details, tables with a header row, math, links and basic marks. Lost: text color, highlight, underline, comment marks, alignment, merged or colored cells, columns, mentions, embeds, diagrams (become images). Tables without a header row get an empty header. Before 0.97, tables export with a broken header. Conclusion: use `append` for routine writes and never send a whole-page `replace` built from a Markdown round trip of a rich page | bbik52 `docs/docmost-api-notes.md` |
| 3 | Response shapes | Resolved on paper. Lists take `limit` 1 to 100 (more answers 400) and an opaque `cursor`, and return `meta.nextCursor` and `meta.hasNextPage`. `search` returns `items` without `meta`. `comments/create` needs `content` as a JSON string of a ProseMirror document; plain text answers 400. Errors look like `{message, statusCode}`. A page or space without access answers 404, not 403 | bbik52 notes |
| 4 | Reuse the `JwtStrategy` OAuth branch | Not needed. The sidecar issues its own OAuth tokens and calls Docmost with the member's session JWT as `Authorization: Bearer`. Docmost needs no changes | Design |
| 5 | Login throttle | Partly resolved. About 10 sign-ins per minute (`x-ratelimit-*-auth` headers). Sign-in happens once per member per 90 days, so this does not matter for about 10 users. Do not retry sign-ins automatically | bbik52 notes |
| 6 | SSO enforcement | Not applicable on Community | Handoff |
| 7 | Memory on 1 GB | Open. Budget in section 5.3; must be measured (T-10) | |

New facts from the survey to carry forward:

- `POST /api/version` needs a session, and there is no public version endpoint. `GET /api/health` is public.
- bbik52 sets its minimum supported Docmost to 0.80.1 because of CVE-2026-34212 and CVE-2026-48073 (as cited by bbik52; we have not checked these IDs against an advisory database). Pin a current tag.
- `pages/move` needs a fractional-index `position` of 5 to 12 characters.
- Docmost writes page history about 1 to 5 minutes after the last edit, so it cannot serve as a pre-write backup. That is why bbik52 keeps its own snapshots.

---

## 4. Decision: adopt, fork, or build

| Criterion | A. Adopt upstream image | B. Fork to osh-labs, build own image (recommended) | C. Build our own TypeScript server |
|---|---|---|---|
| Time to production | 1 to 2 days | 3 to 5 days | 3 to 5 weeks |
| Code under our control | No (pinned digest only) | Yes | Yes |
| Supply-chain exposure | Third-party image that handles our passwords at login | We build from reviewed source with a locked dependency set | Our own dependency set |
| Feature level at start | 62 tools, hardened | Same | Handoff minimum (9 tools) |
| Maintenance | Depends on one external maintainer | We merge upstream when we choose to | All ours |
| License | Apache-2.0, compatible with AGPL-3.0 when combined | Same; keep LICENSE and NOTICE | Ours (AGPL in this fork) |
| Main risk | Project abandoned or compromised | Review effort, and Python upkeep | OAuth implementation bugs |

Recommendation: B. The sidecar sees every member's Docmost password at sign-in and holds tokens that can act as them, so we should not run third-party code we have not reviewed. Forking plus a security review gives the time-to-value of A with the control of C. Keep C as the fallback, gated by section 6, Phase 1.

### 4.1 Alternative base for Track B: Rahulk644 (Rust)

| Criterion | bbik52 (Python) | Rahulk644 (Rust) |
|---|---|---|
| License | Apache-2.0 | MIT |
| Sign-in | Its own login page; the sidecar receives the Docmost password and calls `/api/auth/login` | Reuses the user's Docmost browser session. `/oauth/authorize` and `/oauth/resume` must be routed on the Docmost origin so the sidecar can read the `authToken` cookie and validate it with `/api/users/me` (`src/oauth.rs`). The sidecar never handles passwords, but it does get the session JWT |
| Grant storage | Postgres, encrypted; survives restarts | Memory only. Every restart or deploy forces every member to reconnect each client, including on mobile |
| Write safety | Snapshots, read-back, busy check, Trash only | Writes off by default, `confirm: true` per mutation, JSONL audit log, Host and Origin allowlists |
| Tools | 62 | About 20 |
| Memory (estimate) | 80 to 150 MB | Likely under 30 MB (Rust binary; not measured) |
| Extra dependency | Postgres database | None |
| Size | About 10.8k lines of Python | About 7.8k lines of Rust |

Recommendation: start Phase 1 with bbik52, because persistent grants matter for mobile users and snapshots matter for recovery. Switch to Rahulk644 if T-10 shows the Python sidecar does not fit in 1 GB, or if the Phase 1 review fails on password handling. Running Rahulk644 also needs the path-routing change in the Caddyfile on `docs.`.

---

## 5. Target architecture

### 5.1 Topology

```
Claude mobile / claude.ai ──(Anthropic cloud)──HTTPS──┐
Claude Code (laptop) ─────────────────────────HTTPS──┤
Team browsers ────────────────────────────────HTTPS──┤
                                                     ▼
                         Lightsail 1 GB, Ubuntu 24.04, Docker Compose
                         ┌─────────────────────────────────────────────┐
                         │ caddy :80/:443 (TLS, WebSockets, no buffer) │
                         │   docs.southeastexpeditionmed.com ──► docmost:3000            │
                         │   docs-mcp.southeastexpeditionmed.com  ──► docmost-mcp:8000        │
                         │ docmost (upstream image, pinned tag)        │
                         │ docmost-mcp (our build of the fork)         │
                         │   ──► http://docmost:3000/api  (internal)   │
                         │ postgres:18  db: docmost, db: docmost_mcp   │
                         │ redis:8 (AOF, noeviction)                   │
                         └─────────────────────────────────────────────┘
```

- Two host names (`docs.` and `docs-mcp.`), because bbik52 must be served at the root of a host name.
- The sidecar reaches Docmost over the internal Compose network. That needs `DOCMOST_ALLOW_INSECURE_HTTP=true`. This is acceptable because the traffic never leaves the Docker bridge network; record the decision in the deployment README.
- Exposure: make both host names public. Members' browsers must reach `docs.` (editor) and `docs-mcp.` (OAuth sign-in page), and Anthropic's cloud must reach `docs-mcp.`. Keeping the wiki behind Tailscale would block mobile editing in Docmost itself. Revisit if the team only reaches Docmost from managed devices.

### 5.2 Repository layout in this fork

Do not modify `apps/` or `packages/`, so that rebases on upstream Docmost stay conflict-free.

```
deploy/
  compose.yaml              # caddy, docmost, docmost-mcp, postgres, redis
  Caddyfile
  .env.example              # no secrets
  postgres-init/10-mcp.sh   # creates docmost_mcp role and database (first init only)
  scripts/
    backup.sh               # pg_dumpall + storage volume -> S3
    restore.sh
    smoke.sh                # health, login page, /mcp 401 without token
  README.md                 # runbook
mcp/                        # git subtree of osh-labs/docmost-mcp-remote at a pinned tag
                            # (or a separate repo; see decision D-2)
docs/mcp/
  BUILD_PLAN.md             # this file
  SECURITY_REVIEW.md        # Phase 1 output
  TEST_REPORT.md            # Phase 4 output
  ADR-0001-adopt-docmost-mcp-remote.md
```

### 5.3 Memory budget (1 GB instance)

| Process | Planned RSS | Basis |
|---|---|---|
| Ubuntu + Docker daemon | 150 to 200 MB | Estimate |
| Docmost (Node, API + collab in one process) | 300 to 450 MB | Estimate; third-party guide measured about 600 MB for Docmost + Postgres + Redis together |
| Postgres 18 (two databases) | 60 to 120 MB | Tune `shared_buffers=64MB`, `max_connections=40` |
| Redis 8 | 10 to 30 MB | Small dataset |
| docmost-mcp (Python, uvicorn, 1 worker) | 80 to 150 MB | Estimate; to measure |
| Caddy | 20 to 40 MB | Estimate |
| Total | 620 to 990 MB | Plus a 2 GB swap file |

- Measure at T-10. If steady-state RSS stays above about 850 MB or swap-in is sustained, the options are: (a) the $12 bundle (2 GB), which breaks the $10 budget; or (b) cap Docmost with `NODE_OPTIONS=--max-old-space-size=384` and test. Option (b) is not validated.
- Removing bbik52's separate Postgres container saves an estimated 50 to 100 MB.

---

## 6. Phased build plan

Each phase ends in a pull request to `claude/vigilant-einstein-4cbnn3`, or to a branch the owner names, with its exit criteria met. Do not start a phase until the previous one is merged.

### Phase 0: Decisions and accounts (owner, about 1 hour)

| ID | Task | Output |
|---|---|---|
| 0.1 | Answer the open decisions in section 11 (D-1 to D-6) | Comment on the PR |
| 0.2 | Create Cloudflare DNS A records (DNS only) for `docs.` and `docs-mcp.` | DNS |
| 0.3 | Create a Lightsail 1 GB instance with a static IP; open firewall ports 22 (restricted), 80 and 443 | Instance |
| 0.4 | Create an S3 bucket and an IAM user scoped to `PutObject` and `GetObject` on that bucket only | Credentials, held outside git |
| 0.5 | Fork `bbik52/docmost-mcp-remote` to `osh-labs/docmost-mcp-remote` and add it to the agent session | Fork |

### Phase 1: Security review of the MCP sidecar (gate, 1 to 1.5 days)

Goal: decide between B and C based on evidence. Review a pinned commit (current `a5e3624`, v1.2.3).

| ID | Task | Pass condition |
|---|---|---|
| 1.1 | Dependency audit: `uv.lock` with `pip-audit` and OSV; check `fastmcp` 4.x and `mcp` SDK versions for open advisories | No unfixed high or critical findings |
| 1.2 | Credential handling: trace the password from the login form to `/api/auth/login`; confirm it is never logged, stored (with `RELOGIN_MODE=ask`) or sent anywhere but `DOCMOST_URL`; review `crypto.py` (algorithm, nonce, key derivation, rotation) | Password used once in memory; AEAD encryption with a unique nonce |
| 1.3 | OAuth: review `oauth.py` against the MCP authorization spec (exact redirect URI, PKCE S256 required, `resource` binding, access-token TTL, refresh rotation, code single-use and TTL, DCR limits) | No deviations that allow token theft or replay |
| 1.4 | Outbound network: grep for any egress other than `DOCMOST_URL` (telemetry, update checks, registry calls) | None |
| 1.5 | Web pages: CSRF, CSP, cookie flags, open redirects on the consent and return pages | No open redirect; CSRF on POSTs |
| 1.6 | Authorization: confirm every Docmost call uses the calling member's token, and that `ALLOWED_SPACES` and scopes are enforced server-side before the call | No shared or admin token path |
| 1.7 | Upload and download links: TTL, entropy, scope | Matches the security model doc |
| 1.8 | Run their unit and integration test suites (CI uses real Docmost) | Green |
| 1.9 | Write `docs/mcp/SECURITY_REVIEW.md` with findings and a go/no-go | Owner signs off |

Exit: go means proceed with B. No-go for an unfixable reason means Track C (section 7). Fixable findings become patches on the fork, offered upstream as pull requests.

### Phase 2: Local stack (0.5 day)

| ID | Task | Detail |
|---|---|---|
| 2.1 | Write `deploy/compose.yaml` | Pin `docmost/docmost:<current tag>` (check the latest release; at least 0.97.0); `postgres:18`; `redis:8 --appendonly yes --maxmemory-policy noeviction`; `docmost-mcp` built from `mcp/` or the fork's image at a digest; `caddy:2`. Memory limits per service (`mem_limit`). `read_only`, `cap_drop: ALL` and `no-new-privileges` for the sidecar, as in its compose file |
| 2.2 | Postgres init | `postgres-init/10-mcp.sh` creates the `docmost_mcp` role and database. Sidecar `DATABASE_URL=postgresql://docmost_mcp:...@postgres:5432/docmost_mcp` |
| 2.3 | Environment | Docmost: `APP_URL=https://docs.southeastexpeditionmed.com`, `APP_SECRET`, `DATABASE_URL`, `REDIS_URL`; leave `COLLAB_DISABLE_REDIS` unset. Sidecar: `PUBLIC_URL=https://docs-mcp.southeastexpeditionmed.com`, `DOCMOST_URL=http://docmost:3000`, `DOCMOST_ALLOW_INSECURE_HTTP=true`, `SECRET_KEY`, `ALLOWED_EMAILS` (team list), `RELOGIN_MODE=ask`, `TOOL_CALLS_PER_MINUTE=60`, `MAX_PAGE_CHARS=60000`, `SNAPSHOT_RETENTION_DAYS=30`, `AUDIT_RETENTION_DAYS=90` |
| 2.4 | Caddyfile | Two sites; `reverse_proxy` with `flush_interval -1` on `docs-mcp.` (no response buffering for streams); WebSockets pass through by default for `docs.`; HSTS; `request_body max_size` on `docs-mcp.` matching `UPLOAD_MAX_MB` |
| 2.5 | Bring up locally with self-signed TLS or a tunnel; create the workspace through the first-run setup; create 2 test users and 2 spaces with different membership | Stack up |
| 2.6 | `deploy/scripts/smoke.sh` | `GET /api/health` returns 200; `GET mcp/healthz` returns 200; `POST mcp/mcp` without a token returns 401 with a `WWW-Authenticate` header pointing to protected-resource metadata; `/.well-known/oauth-protected-resource/mcp` lists `resource` equal to `https://docs-mcp.southeastexpeditionmed.com/mcp` |

Exit: `smoke.sh` passes locally.

### Phase 3: Functional verification against our Docmost tag (1 day)

Run with Claude Code and the static bearer first (cheapest loop), then OAuth. Record results in `docs/mcp/TEST_REPORT.md`.

| Test | Procedure | Expected |
|---|---|---|
| T-01 Sign-in | Connect Claude Code with `claude mcp add --transport http`, then complete `/mcp` sign-in | Grant with `read` only unless ticked |
| T-02 Permission isolation | User A in space 1 only; ask it to list spaces, search for a term that exists only in space 2, and get a space-2 page by ID | Space 2 is invisible; the get answers "not found" |
| T-03 Body write | `create_page` with Markdown, `update_page` append and prepend; check in the editor | Content visible in the editor and in `pages/info`; no silent no-op |
| T-04 Live-edit conflict | User B has the page open and is typing; user A runs append, then replace | Append merges without lost keystrokes; replace refused while B saved in the last 60 s; record what B's editor shows |
| T-05 Fidelity | Page with a table with header, task list, callout, math block, code block, Mermaid or draw.io diagram, mention; `get_page`, then `replace_section` on an unrelated section | Untouched sections keep their formatting; record the losses |
| T-06 Comments | `add_comment` and a reply; `list_comments` | Appears in the editor with the correct author |
| T-07 Scopes | Grant without `write`; call `create_page` | Tool hidden or refused |
| T-08 Revocation and expiry | Revoke the grant on `/account`; separately, expire the Docmost token (set `JWT_TOKEN_EXPIRES_IN=5m` on a test stack) | Next call fails closed; member is told to sign in again |
| T-09 Throttle | 10 members sign in within 1 minute (script against the login page) | Record the 429 point; no lockout of the Docmost account beyond the window |
| T-10 Memory | 10 simulated editors (Playwright opening pages and typing) + 20 MCP calls per minute for 30 min; `docker stats` every 10 s | Peak RSS and swap recorded; no OOM kill |
| T-11 Output caps | `get_page` on a page larger than 60000 characters; search with a 500-character query | Truncated with a notice; query rejected or capped |
| T-12 Audit | `admin audit` after the tests | Entries have user, tool and page id, and no content |

Exit: T-01 to T-08 and T-11 to T-12 pass. T-09 and T-10 results are recorded and accepted by the owner.

### Phase 4: Lightsail deployment (0.5 day)

| ID | Task |
|---|---|
| 4.1 | Ubuntu 24.04 hardening: non-root sudo user, SSH keys only, `PasswordAuthentication no`, unattended-upgrades, UFW allowing only 22 (from admin IPs or Tailscale), 80 and 443 |
| 4.2 | 2 GB swap file, `vm.swappiness=10` |
| 4.3 | Docker Engine and the Compose plugin from Docker's apt repository |
| 4.4 | Copy `deploy/`; write `.env` with secrets from `openssl rand -hex 32` (`APP_SECRET`, `SECRET_KEY`, DB passwords); `chmod 600`; keep a copy of `SECRET_KEY` in the team password manager (losing it signs everyone out and makes snapshots unreadable) |
| 4.5 | `docker compose up -d`; Caddy obtains certificates; run `smoke.sh` against public URLs |
| 4.6 | fail2ban (or CrowdSec) jail on Caddy access logs for repeated 401 and 429 on `/api/auth/login` and on the sidecar `/login` |
| 4.7 | Optional: Tailscale for SSH and DB admin only |

### Phase 5: Claude connector rollout (0.5 day)

| ID | Task | Expected |
|---|---|---|
| 5.1 | claude.ai: Settings > Connectors > Add custom connector, URL `https://docs-mcp.southeastexpeditionmed.com/mcp` | Browser opens the sidecar sign-in, then consent, then returns to Claude |
| 5.2 | Claude mobile: confirm the connector appears and works (connectors added on claude.ai sync to mobile, per Anthropic docs; verify) | `list_spaces` works from the phone |
| 5.3 | If the org uses a Team or Enterprise plan, an owner adds the connector at org level | Members see it |
| 5.4 | Per-member onboarding sheet: how to add the connector, which scopes to tick (recommend `read` + `write`; `delete` and `admin` off), how to revoke at `/account` | One page in the wiki |

### Phase 6: Backups and restore (0.5 day)

| ID | Task |
|---|---|
| 6.1 | `backup.sh`: `pg_dumpall` (both databases), tar of the `docmost` storage volume, upload to S3 with date keys; cron nightly; S3 lifecycle rule (for example 30 daily, 12 monthly) |
| 6.2 | Store `.env` (encrypted, for example with `age`) separately from the DB dump, because the sidecar DB holds encrypted tokens and snapshots |
| 6.3 | `restore.sh` on a clean Lightsail instance (temporary, delete after); verify pages, attachments, a member's MCP grant still works |
| 6.4 | Record restore time and result in `TEST_REPORT.md` |

### Phase 7: Operations

| Item | Practice |
|---|---|
| Docmost upgrades | Read release notes, bump the pinned tag on a staging Compose stack (local), rerun T-03, T-05 and T-06, then deploy. Watch for changes to `pages/update`, `search` and comment DTOs |
| Sidecar upgrades | `git fetch upstream` in the fork, review the diff (the upstream project is new and moves fast), rerun the Phase 3 subset |
| Monitoring | Lightsail metric alarms (CPU, status check); external uptime check on `/api/health` and `mcp/healthz`; weekly `admin audit` review |
| Retention | Snapshots 30 days, audit 90 days (defaults) |

---

## 7. Track C (fallback): our own TypeScript server

Use only if Phase 1 returns no-go. Keep the same deployment (sections 5 and 6); replace the sidecar.

| Step | Scope | Reference |
|---|---|---|
| C1 | Package `mcp/` with Node 22, `@modelcontextprotocol/sdk` (Streamable HTTP, stateless mode), Express, `pg`, `zod` | Handoff section 7 |
| C2 | Docmost client: `login`, `search`, `pages/info` (markdown), `pages/create`, `pages/update`, `spaces`, `pages/sidebar-pages`, `comments`, `comments/create`; envelope unwrapping, `cursor` pagination, 404 means "not found or no access" | Sections 2.2 and 3; YugenLabsTI `docs/docmost-api-v0.96.0.md` and bbik52 `docs/docmost-api-notes.md` as written specs (Apache-2.0; credit it in NOTICE if text is adapted) |
| C3 | OAuth 2.1 authorization server: DCR (RFC 7591), authorization code + PKCE S256, RFC 8707 resource, protected-resource metadata (RFC 9728), refresh rotation, access TTL 1 h; optionally CIMD | Section 10 |
| C4 | `/authorize` page: Docmost email and password, CSRF, per-IP and per-email limits, encrypted Docmost token (AES-256-GCM, key from env, key id for rotation) | |
| C5 | Tools (minimum): `search_pages`, `get_page`, `list_spaces`, `list_pages`, `create_page`, `update_page` (append and prepend; replace gated), `list_comments`, `create_comment`, `move_page` | Handoff 7.4 |
| C6 | Safety: read-back after write, pre-write snapshot table, untrusted-content wrapper, size caps, audit table, per-member rate limit | bbik52 ADR 0004 (design ideas, not code) |
| C7 | Tests: unit tests, plus integration tests against a Docmost container in CI | |

Estimate: C1 to C5, 1.5 to 2 weeks; C6 to C7, 1 to 2 weeks (agent time, assumption).

---

## 8. Licensing

| Component | License | Obligation |
|---|---|---|
| Docmost (upstream image, unmodified) | AGPL-3.0 | None beyond the license for an unmodified copy. If we later modify Docmost, offer our source to network users (section 13) |
| `packages/ee`, `apps/client/src/ee` | Docmost commercial terms | Not used; nothing in this plan reconstructs EE features inside Docmost |
| docmost-mcp-remote fork | Apache-2.0 | Keep LICENSE and NOTICE; mark modified files; Apache-2.0 code may be combined with AGPL-3.0 code |
| Our deployment files | Covered by this repository's AGPL-3.0 | None extra |

Open item (from handoff section 4): an MCP sidecar is a separate program that calls the REST API, which plausibly avoids an EE-license question. Still, someone should read Docmost's Subscription Terms (https://docmost.com/terms) before production use. This is not legal advice.

---

## 9. Risk register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Prompt injection in a page makes an agent with `write` change other pages | Medium | Medium | Scopes per client; untrusted wrapper; snapshots; Trash only; default `read`; `ALLOWED_SPACES` for sensitive spaces |
| R2 | Sidecar compromise exposes Docmost sessions for all members | Low | High | Phase 1 review; own build; read-only container; `SECRET_KEY` outside DB backups; patch cadence |
| R3 | Upstream sidecar abandoned | Medium | Low | We hold the fork; Track C spec exists |
| R4 | Docmost changes the REST contract in a release | Medium | Medium | Pinned tag; Phase 7 upgrade test |
| R5 | OOM on 1 GB | Medium | High | Swap, memory limits, T-10, $12 bundle fallback |
| R6 | `replace` discards live edits or formatting | Medium | Medium | 60 s busy check; prefer append and `replace_section`; snapshot restore |
| R7 | Password guessing on public login pages (no MFA on Community) | Medium | High | Long unique passwords, Docmost and sidecar rate limits, fail2ban, `ALLOWED_EMAILS` |
| R8 | Anthropic changes connector OAuth requirements | Low | Medium | Track the connector docs; CIMD support available as a later patch |

---

## 10. Claude connector requirements (current docs)

- Claude can register through Client ID Metadata Documents, Dynamic Client Registration (RFC 7591), or a client ID and secret entered in the connector's advanced settings. It uses CIMD only if the server advertises `client_id_metadata_document_supported: true`; otherwise DCR, which bbik52 implements.
- The protected-resource metadata `resource` must exactly match the URL entered in Claude, so enter `https://docs-mcp.southeastexpeditionmed.com/mcp`. bbik52 normalizes trailing slashes and default ports (v1.2.2).
- The OAuth callback is `https://claude.ai/api/mcp/auth_callback`. Anthropic says it may move to `https://claude.com/api/mcp/auth_callback`, so allow both. Claude Code uses loopback callbacks with any port.
- Connector calls originate from Anthropic's cloud, so `docs-mcp.` must be publicly reachable over HTTPS. Do not IP-restrict it unless Anthropic's published egress ranges are used and kept current.

---

## 11. Decisions (answered by the owner, 2026-11-09)

| ID | Decision | Answer |
|---|---|---|
| D-1 | Track B (fork bbik52) or Track C (build in TypeScript) | B: fork and adopt, gated by the Phase 1 review |
| D-2 | Sidecar source location | Separate repo `osh-labs/docmost-mcp-remote`; image referenced by digest; this repo holds `deploy/` |
| D-3 | Host names | Wiki `docs.southeastexpeditionmed.com`; MCP `docs-mcp.southeastexpeditionmed.com`; DNS in Cloudflare (see 11.1) |
| D-4 | Default scopes | `read` + `write`; `delete` and `admin` for the owner only |
| D-5 | `RELOGIN_MODE` | `ask` (members sign in again every 90 days) |
| D-6 | Budget | $12 bundle (2 GB) acceptable if T-10 fails on 1 GB |
| D-7 | Agent-written @-mentions | Allowed (comments and page edits). Members are told that mentions send Docmost notifications |

### 11.1 Cloudflare notes

- Start with both records as DNS only (grey cloud). Caddy then obtains Let's Encrypt certificates directly, and nothing sits between Anthropic's cloud and the MCP server.
- If proxying (orange cloud) is wanted later for `docs.`: set SSL mode to Full (strict); WebSockets are supported on all plans; proxied requests time out after 100 s without a response.
- Keep `docs-mcp.` DNS only, or, if proxied, exempt it from Bot Fight Mode and WAF challenges. A JavaScript challenge would block Anthropic's server-to-server calls and the OAuth token exchange.

---

## 12. Acceptance criteria mapping (handoff section 11)

| Handoff criterion | Verified by |
|---|---|
| 1. Boots on 1 GB and stays stable with 10 editors | Phase 4, T-10 |
| 2. Claude mobile adds connector, completes OAuth, lists spaces | Phase 5.1 to 5.2 |
| 3. Users see only their own spaces and pages | T-02 |
| 4. Search, get, create, append work, and render in the editor | T-03, T-05 |
| 5. Expired or revoked tokens fail closed | T-08 |
| 6. Backup restore verified | Phase 6.3 |

---

## 13. Sources

- GitHub repository search API, queries listed in section 2, run 2026-11-09
- https://github.com/bbik52/docmost-mcp-remote (README, `docs/DESIGN.md`, `docs/docmost-api-notes.md`, `docs/security-model.md`, `docs/adr/0002` to `0004`, `CHANGELOG.md`; commit `a5e3624`)
- https://github.com/abelsr/docmost-mcp-oss
- https://github.com/YugenLabsTI/shrd-docmost-mcp (`docs/docmost-api-v0.96.0.md`), https://github.com/glinhard/docmost-cli (`SPECIFICATION.md`)
- https://github.com/Rahulk644/docmost-mcp, https://github.com/wisflux/docmost-local-mcp, https://github.com/mauriciosoares01/docmost-mcp, https://github.com/dilruwanm/docmost-community-mcp, https://github.com/punyamsingh/docmost-mcp, https://github.com/MrMartiniMo/docmost-mcp, https://github.com/ggpo1/docmost-sdk
- Claude connector authentication: https://claude.com/docs/connectors/building/authentication
- Building custom connectors via remote MCP: https://support.anthropic.com/en/articles/11503834-building-custom-connectors-via-remote-mcp-servers
- This repository at `863352b`: `apps/server/src/core/page/services/page.service.ts`, `apps/server/src/collaboration/collaboration.gateway.ts`, `apps/server/src/integrations/environment/environment.service.ts`, `docker-compose.yml`
- Handoff notes, sources section (Docmost editions, pricing, MCP docs, Lightsail pricing)
