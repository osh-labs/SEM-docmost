# Security review 2: OAuth, authorization, outbound network

Target: `bbik52/docmost-mcp-remote` at commit a5e3624 (v1.2.3). Static review only; nothing from the project was run.
Paths below are relative to `src/docmost_mcp_remote/` unless prefixed.

Library code was also read, because much of the OAuth logic lives there and not in the project:
- `mcp` 2.3.0 (the version pinned in `uv.lock`), read from the locally installed package (`site-packages/mcp/server/auth/...`).
- `fastmcp-slim` 4.1.3 (the version pinned in `uv.lock`), downloaded as a wheel and only unpacked and read.

Line numbers for library files refer to those versions. A different resolved version could behave differently. The lock file pins exactly these versions, so this risk is low.

## Verdicts

| Item | Verdict |
|---|---|
| 1.3 OAuth 2.1 / MCP authorization | PASS WITH NOTES (1 Medium, 3 Low, several Info) |
| 1.6 Authorization (per-member token, scopes, ALLOWED_SPACES / ALLOWED_EMAILS) | PASS WITH NOTES (1 Low, several Info) |
| 1.4 Outbound network | PASS (Info notes only) |

No Critical or High findings.

---

## 1.3 OAuth

### Checklist results

| Check | Result | Evidence |
|---|---|---|
| Exact redirect URI matching | PASS | SDK `OAuthClientInformationFull.validate_redirect_uri` checks `redirect_uri not in self.redirect_uris`, which is exact `AnyUrl` equality (mcp `shared/auth.py:187-198`). It runs in the authorize handler (mcp `handlers/authorize.py:174-178`). The consent step reuses the stored, already validated `params.redirect_uri` (`web/routes.py:405`, `:424`, `:436`). If the client omits redirect_uri, the server uses the registered URI, but only when exactly one is registered. |
| Loopback port handling | PASS (strict) | Ports are not wildcarded. The port must match the registered URI exactly. Registration accepts `http` only for the host `localhost` or a loopback IP (`oauth.py:69-76`). Claude Code registers a fresh client per port, so this works. RFC 8252 "any port" flexibility is absent, which is safer. |
| PKCE S256 required, plain refused | PASS | `code_challenge` is a required field and `code_challenge_method: Literal["S256"]` (mcp `handlers/authorize.py:32-33`), so `plain` fails validation. |
| Missing verifier refused | PASS | `code_verifier: str = Field(...)` is required (mcp `handlers/token.py:31`). It is verified by SHA-256 against the stored challenge (`token.py:186-194`). |
| Code single use | PASS | `use_code` is an atomic `UPDATE ... WHERE used_at IS NULL` (`db/oauth_store.py:217-229`), called in `exchange_authorization_code` (`oauth.py:273-275`). A replayed code revokes the whole grant and its tokens (`oauth.py:251-254`, `:274`). |
| Code TTL | PASS | 5 minutes (`oauth.py:46`). Stored as `expires_at` (`oauth_store.py:184`) and enforced by the SDK (mcp `handlers/token.py:156`). Codes are stored only as SHA-256 hashes (`oauth_store.py:176`). |
| Code bound to client_id | PASS | `stored.client_id != client.client_id` returns None (`oauth.py:247`). The SDK also compares with `token_request.client_id` (`token.py:144`). |
| Code bound to redirect_uri | PASS | SDK `token.py:164-181` compares the token request's redirect_uri with the one stored at authorize time, for both "provided explicitly" and implicit cases. |
| RFC 8707 resource at authorize | PASS | A `resource` other than `<PUBLIC_URL>/mcp` is refused with `invalid_target` (`oauth.py:223-232`, comparison `oauth.py:84-97`, `:154-161`). The request is always bound to `resource_url` even when the client sends none (`oauth.py:233`). |
| Audience validated on every MCP request | PASS | `load_access_token` rejects access tokens whose stored `resource` is not this server's MCP URL (`oauth.py:359-360`). FastMCP wraps `/mcp` in `RequireAuthMiddleware` (fastmcp `server/http.py:699-707`), and `BearerAuthBackend` calls `verify_token` -> `load_access_token` (fastmcp `server/auth/auth.py:475-484`, `:1009-1022`). Personal tokens carry no resource. They are minted by this server for this server only (`db/store.py` `create_personal_token`, kind `personal`). |
| Access-token TTL | PASS | 1 hour (`oauth.py:44`). Expiry is enforced in `find_token` (`db/store.py:297-299`) and again in the SDK bearer backend (mcp `middleware/bearer_auth.py:71`). |
| Token storage hashed | PASS | Tokens are 256-bit random values with a `dmr_` prefix (`crypto.py:91-93`). Only the SHA-256 hash is stored (`crypto.py:96-98`, `oauth_store.py:263`). A 10-character `hint` is stored (`oauth_store.py:264`): the 4-character prefix plus 6 random characters, which is negligible. |
| Refresh rotation | PASS | `replace_refresh_token` is an atomic `UPDATE ... WHERE replaced_at IS NULL` (`oauth_store.py:320-330`). A new pair is issued on every refresh (`oauth.py:308-325`). Refresh tokens cannot be used as access tokens: `find_token` filters `kind IN ('personal','access')` (`db/store.py:286`). |
| Refresh reuse detection | PASS | A reused (already replaced) refresh token revokes the whole grant (`oauth.py:295-297`, `:316-318`). `load_token` deliberately still returns replaced tokens so reuse is detected (`oauth_store.py:303`). |
| Refresh TTL | PASS WITH NOTE | 30 days, enforced by the SDK (mcp `token.py:215`). The window slides with each rotation and there is no absolute grant lifetime (Info I-3). |
| Revocation | PASS | RFC 7009 endpoint is enabled (`oauth.py:143`). Revoking any token revokes the grant and all of its tokens (`oauth.py:375-384`). The SDK only revokes when `token.client_id == client.client_id` (mcp `handlers/revoke.py`). Members can revoke grants on the account page, scoped to their own grants (`web/routes.py:328-343`, `db/store.py:233-247`). The admin CLI has `revoke-member` (`admin.py:52`). Revocation takes effect on the next request because every lookup joins `grants.revoked_at IS NULL` (`db/store.py:288`). |
| ALLOWED_EMAILS / disabled member on OAuth paths | PASS | Checked at web session (`web/routes.py:161-175`), code load (`oauth.py:249`), refresh load (`oauth.py:293`), access token load (`oauth.py:357`), and every Docmost call (`members.py:165-169`). |
| DCR abuse limits | PASS WITH NOTES | 10 registrations per IP per hour (`oauth.py:55`, `:108-129`, `:163-173`). At most 1000 never-used clients, with eviction of expired unused ones (`oauth.py:53`, `:202-212`). At most 10 redirect URIs of up to 2000 characters each (`oauth.py:54`, `:189-199`). `client_name` is limited to 200 characters (`:200`). Unused clients are deleted after 1 hour (`oauth_store.py:24`, `:344-351`). See L-2 for limits that are missing. |
| Redirect URI scheme validation | PASS WITH NOTES | `javascript`, `data`, `file`, `vbscript`, `about`, `blob` and `ftp` are refused. Fragments are refused. `http` is allowed only for loopback. `https` is allowed for any host. Any other custom scheme is allowed (`oauth.py:57-77`). Userinfo is not refused (L-1). Any https host is accepted (M-1). |
| Protected-resource metadata | PASS | FastMCP adds RFC 9728 routes via `create_protected_resource_routes` (fastmcp `server/auth/auth.py:1117-1123`). |
| WWW-Authenticate on 401 | PASS | `RequireAuthMiddleware` gets `resource_metadata_url` (fastmcp `server/http.py:688-707`). The header includes `resource_metadata=` (mcp `bearer_auth.py:136-155`). |
| Token comparison timing | PASS | Bearer tokens, codes, refresh tokens and consent request ids are looked up by SHA-256 hash in the database. No string compare runs on the secret itself. CSRF tokens use `hmac.compare_digest` (`crypto.py:101-102`, `web/routes.py:177-184`). Client secrets use `hmac.compare_digest` (mcp `middleware/client_auth.py:113`). |
| PKCE downgrade via JWT-bearer / CIMD | PASS | The JWT-bearer (ID-JAG) grant is refused: registration rejects it (mcp `handlers/register.py:97-102`) and FastMCP leaves `identity_assertion_enabled` off. CIMD (URL client ids) is wired only into FastMCP's `OAuthProxy` (fastmcp `server/auth/oauth_proxy/proxy.py`), not into `OAuthProvider`, which this project uses. `private_key_jwt` registration is refused (mcp `register.py:57-61`). |
| Consent page integrity | PASS | Every authorization requires a signed-in web session and an explicit "Allow". There is no auto-approval (`web/routes.py:362-439`). CSRF is tied to the session (`:391`). Each answer is single use because the pending request is deleted first (`:397-399`). Granted scopes are `{"read"} | (ticked & requested & allowed)` (`:415`). The page cannot be framed, is not cached and sends no referrer (`:43-53`). Cookies are HttpOnly, SameSite=Lax, `__Host-` and Secure over https (`:94-99`, `:137-146`). `safe_next` blocks open redirects (`:62-66`). |
| No unauthenticated path to tools/resources/prompts | PASS | `/mcp` sits behind `RequireAuthMiddleware` (fastmcp `server/http.py:699-707`). Every `@mcp.tool`, `@mcp.resource` and `@mcp.prompt` has `auth=require_scopes(...)` (see the 1.6 scope table). The completion handler refuses without a member (`tools/resources.py:176-179`), and completion is only reachable through `/mcp`. Custom routes outside `/mcp` (`server.py:185-194`): `/healthz` (version only), the web pages (session cookie), `/downloads/{token}` and `/uploads/{token}...` (capability URLs, see L-3). STDIO skips component auth (fastmcp `server/server.py:255-268`), but STDIO is only used by `--tool-catalog`, which runs with `auth=None` plus `CatalogOnly`, refuses every call and has no Docmost or database (`__main__.py`, `server.py:105-118`, `guard.py:122-137`). |

### Findings (1.3)

#### M-1 (Medium): Open DCR plus spoofable client name allows consent phishing for any https redirect host

- **Description.** Anyone on the internet can register a client (`oauth.py:183-216`) with any `https://` redirect URI (`oauth.py:67-68`) and any `client_name`. The server has no setting to restrict redirect hosts (for example to `claude.ai` / `claude.com` and loopback). The consent page shows the attacker-chosen name ("Allow **Claude** to use Docmost as you?") and the redirect host as small muted text (`web/templates/consent.html`).
- **Exploit scenario.**
  1. The attacker POSTs `/register` with `client_name="Claude"` and `redirect_uris=["https://claude-connector.example/cb"]`.
  2. The attacker builds `/authorize?client_id=...&code_challenge=<their S256>&scope=read write delete admin&...` and sends it to a team member ("re-connect your Docmost connector").
  3. The member is already signed in to the web session, sees a consent page that looks routine, ticks write, and clicks Allow.
  4. The code goes to the attacker's host, and the attacker exchanges it with their verifier.
  5. The attacker now acts in Docmost with that member's rights. The access lasts as long as they keep refreshing (30-day sliding window), until the member notices the grant on the account page.
- **Mitigating factors.** The member must be authenticated and must click Allow. The redirect host is displayed. Write, delete and admin are unticked by default. The grant is listed and revocable on `/account`.
- **Suggested fix.** Restrict redirect URIs to an allowlist. You can patch `redirect_uri_allowed` so `https` passes only for `claude.ai` and `claude.com` with path `/api/mcp/auth_callback`, keeping loopback `http` for Claude Code. Or enforce the same rule at the reverse proxy by inspecting `POST /register` bodies. Also consider showing the full redirect URI prominently and marking clients as "unverified" unless their redirect host is allowlisted. Teach members to connect only from inside Claude.

#### L-1 (Low): Redirect URIs with userinfo are accepted and shown misleadingly on the consent page

- **Description.** `redirect_uri_allowed` does not reject `user:pass@` (`oauth.py:61-77`). `_redirect_host` displays `urlsplit(uri).netloc`, which includes the userinfo (`web/routes.py:79-81`).
- **Exploit scenario.** The attacker registers `https://claude.ai@attacker.example/cb`. The consent page says "you are sent back to `claude.ai@attacker.example`", which a hurried reader parses as claude.ai. This amplifies M-1.
- **Suggested fix.** Refuse URIs where `parts.username` or `parts.password` is set. Display `parts.hostname` (plus port) only.

#### L-2 (Low): Rate limits are missing or only per IP on unauthenticated OAuth endpoints

- **Description.**
  - `/authorize` has no rate limit. Each valid call inserts a row into `oauth_requests` holding the full `AuthorizationParams` JSON, including an unbounded `state` (`oauth.py:236-238`, `oauth_store.py:111-122`). Rows live 15 minutes and are purged hourly (`server.py:54`, `oauth_store.py:352-354`).
  - The DCR limit is keyed by `scope["client"]` (`oauth.py:117-118`). That key is only the real client IP if `FORWARDED_ALLOW_IPS` matches the reverse proxy. If it does not, all registrations share one bucket of 10 per hour. Even when configured correctly, registrations from Claude.ai come from Anthropic egress IPs, so team members connecting through Claude.ai may share a bucket.
  - Login attempts are also limited per IP (`web/routes.py:102`, `:232`).
- **Exploit scenario.**
  - An unauthenticated attacker with one registered client loops `/authorize` with about 60 KB `state` values to grow Postgres. The impact is availability only.
  - Separately, an attacker can exhaust the shared registration bucket so legitimate Claude.ai connects fail for up to an hour.
- **Suggested fix.** Rate limit `/authorize`, `/register`, `/token` and `/login` at the reverse proxy. Cap the `state` length. Set `FORWARDED_ALLOW_IPS` to the proxy address exactly. Watch registration 429s after go-live with 10 users.

#### L-4 (Low): Personal tokens can be created with no expiry

- **Description.** The account page offers `never` (`web/routes.py:41`, `:315-316`). A non-expiring bearer with write or delete scope is a long-lived credential. It stops working only through revocation, member disable, or removal from ALLOWED_EMAILS.
- **Exploit scenario.** A token pasted into a Claude Code config or dotfile leaks. It stays valid until someone notices.
- **Suggested fix.** Policy: forbid `never`, or patch `_TOKEN_LIFETIMES` to cap the lifetime at 90 days. Review grants periodically with `docmost-mcp-remote admin`.

#### Info notes (1.3)

- **I-1.** The token endpoint ignores the RFC 8707 `resource` parameter. It neither validates it nor returns `invalid_target`. The issued token is always bound to `/mcp` anyway (`oauth.py:233`, `:280`), so there is no security impact.
- **I-2.** Scopes widen again after narrowing on refresh. If a client refreshes with a narrower `scope`, the new refresh token stores `token_scopes`. A later refresh with no `scope` gets `scopes == refresh_token.scopes`, so `narrowed=None` and `scopes=None` are stored, and the token again carries the full grant scopes (`oauth.py:319`, `oauth_store.py:267`, `:305-307`). It never exceeds what the member consented to.
- **I-3.** There is no absolute grant lifetime. Refresh rotation resets the 30-day window each time (`oauth_store.py:252`), so an active client stays authorized indefinitely until revoked.
- **I-4.** DCR `client_secret` values are stored in plaintext inside `oauth_clients.info` JSON (`oauth.py:215`). Database read access would allow impersonating confidential clients. A code or refresh token is still needed to obtain tokens. Tokens themselves are hashed.
- **I-5.** Replay of a used code, or reuse of a refresh token, revokes the grant before PKCE is checked (`oauth.py:251-254`, `:295-297`). Anyone who learned a used code or old refresh token (plus a public client_id) can therefore force-revoke a member's grant. This is denial of service only. It is the RFC-recommended behaviour.
- **I-6.** `code_verifier` length and charset (RFC 7636: 43-128 unreserved characters) are not validated (mcp `token.py:186`). The impact is negligible.
- **I-7.** `/healthz` discloses the exact server version without authentication (`server.py:185-187`).
- **I-8.** Other DCR metadata fields (`client_uri`, `logo_uri`, `tos_uri`, `contacts`, ...) have no length caps beyond the request body size. They are never fetched or rendered.

---

## 1.6 Authorization

### Per-member Docmost token: PASS

- Every Docmost API call goes through `MemberService.run(member_id, ...)` (`members.py:161-179`). It decrypts that member's own stored JWT, using AES-GCM with the member id as associated data (`members.py:105-120`, `crypto.py:58-84`), and builds `CeDocmostSession(client, token)`.
- `member_id` always comes from the verified token's claims (`auth.py` `current_member_id`; `tools/common.py:34`; `tools/resources.py:177`).
- Capability links carry it encrypted and authenticated (`web/downloads.py:80-101`, `web/uploads.py:399`).
- No shared, admin or service token exists anywhere:
  - `CeDocmostClient` has no credential of its own (`docmost/ce.py:90-109`).
  - Its only unauthenticated calls are `GET /api/health` (`ce.py:114-124`) and `POST /api/auth/login` with the member's own credentials (`ce.py:126-131`).
  - The admin CLI does not call Docmost (`admin.py`).
  - Re-login uses the member's own stored password, and only in `stored_password` mode (`members.py:141-159`).
- The Docmost version cache (`tools/common.py:47-60`) is global, but it holds only the version number.

### Scopes enforced server-side: PASS

- FastMCP 4.1.3 evaluates each component's `auth` when it resolves a tool or prompt for a call (`get_tool` -> `_component_auth_allows`, fastmcp `server/server.py:237-248`, `:902-944`, call path `:1387+`). It does the same for resources and templates (`server.py:1015`, `:1045`, `:1192`) and prompts (`:1324`). So scope checks happen on execution, not only in listings.
- Tool, resource and prompt scope map (from `@mcp.tool(... auth=require_scopes(...))`):
  - **read**: whoami, list_spaces, get_space, list_pages, recent_pages, get_page, get_page_outline, get_section, search, list_comments, list_page_history, get_page_version, diff_page, list_backlinks, list_labels, find_pages_by_label, suggest, get_page_tree, check_space_health, list_space_members, list_workspace_members, list_groups, list_group_members, list_invitations, export_page, export_space, list_attachments, get_attachment, get_upload_status, list_trash, list_snapshots, both resources, 4 prompts.
  - **write**: create_page, update_page, replace_page_json, replace_section, rename_page, move_page, move_page_to_space, duplicate_page, add_comment, update_comment, restore_snapshot, restore_page_version, add_labels, remove_label, create_upload_link, upload_attachment, 2 prompts.
  - **delete**: trash_page, restore_page.
  - **admin**: create_space, update_space, add_space_members, change_space_member_role, create_group, update_group, add_group_members, invite_people, resend_invitation, revoke_invitation, change_workspace_role, deactivate_member, activate_member.
  - No component lacks `auth=` (checked with `grep -n 'auth=' tools/*.py` against every `@mcp.tool/resource/prompt`).
- The effective scope is the grant scope intersected with the token scope (`db/store.py:305-307`). `read` is always included (`web/routes.py:314`, `:415`). There is no server-side permanent delete: `pages/delete` is called with `pageId` only (`docmost/ce.py:686-687`).

### ALLOWED_SPACES: PASS WITH NOTES

The mechanism is `SpacePolicy` (`tools/spaces.py:13-47`). ALLOWED_SPACES holds ids or slugs, and the policy resolves them against the member's own space list.

| Tool or path | How the space is determined and checked | Evidence |
|---|---|---|
| page-id tools (get_page, outline, section, update/replace/rename/move/trash, labels, history list, attachments, export_page, create_upload_link, upload_attachment, list_snapshots) | `backend.get_page(ref)`, then `policy.check(page.space_id)`. Only the page's real space counts, so a page id from another space is refused. | `tools/write.py:283-286`, `tools/read.py:222-223`, `:278-279`, `:316-317`, `tools/files.py:119-122`, `tools/labels.py:58-64`, `tools/history.py:56-59` |
| list_comments | `get_page` + check when restricted | `tools/read.py:417-421` |
| update_comment | comment's `space_id` (or its page's), checked | `tools/write.py:762-764` |
| search / suggest / recent_pages / find_pages_by_label / list_backlinks / resource completion | optional `space_id` checked; results filtered to allowed ids | `tools/read.py:363-365`, `:398`; `tools/navigate.py:53-55`, `:73`; `tools/read.py:188-197`; `tools/labels.py:146-158`, `:85-92`; `tools/resources.py:143-155` |
| move_page_to_space | source page checked (`load_page`) and target space checked | `tools/write.py:624-627` |
| duplicate_page | source checked; a different target space is checked | `tools/write.py:666-669` |
| create_page | space checked; parent must be in the same space | `tools/write.py:369-375` |
| move_page | page checked; new parent must be in the same space | `tools/write.py:579-585` |
| restore_page (Trash) | when restricted, the page must be found in the Trash of an allowed space before restore | `tools/write.py:840-845`, `:212-224` |
| get_page_version / restore_page_version / diff_page | the version's `page_id` is loaded and checked. diff_page requires every version or snapshot to belong to the checked page | `tools/history.py:109-110`, `:217-220`, `:144`, `:165-170` |
| snapshots | database queries are scoped by `member_id`, so another member's snapshot is "not found". The page is re-checked before restore | `db/snapshot_store.py:79-108`, `tools/write.py:899-906` |
| get_attachment | `files/info`, then check its `space_id` (or its page) | `tools/files.py:259-264` |
| export_space / list_space_members / check_space_health / get_page_tree / list_pages / list_trash / get_space | `policy.check(space_id)` | `tools/files.py:200`, `tools/manage.py:144`, `tools/health.py:118`, `tools/navigate.py:101`, `tools/read.py:126`, `:162`, `tools/write.py:787` |
| space admin tools | `policy.check`; slug changes and new spaces must keep within ALLOWED_SPACES | `tools/manage.py:126-131`, `:222`, `:249-251`, `:285`, `:332` |
| download links | policy checked when the link is created; grant must still be active when it is opened | `tools/files.py:147-172`, `:200`, `web/downloads.py:96-100` |
| upload links | policy re-checked at "Done" | `web/uploads.py:345-346` |
| resources `docmost://page/...`, spaces | checked / filtered | `tools/resources.py:106`, `:136` |

No bypass was found for page ids that resolve to another space, search results, move_page_to_space, duplicate_page, exports, attachments, history versions or snapshots.

#### L-3 (Low): Download and upload capability URLs work without authentication and are handed to the model

- **Description.**
  - `export_page`, `export_space` and `get_attachment` return a `/downloads/<token>` URL, valid for 10 minutes and usable any number of times (`web/downloads.py:40-41`, `:75-101`).
  - `create_upload_link` returns an `/uploads/<token>` URL, valid for `UPLOAD_RETENTION_MINUTES` (default 60) (`config.py`, `web/uploads.py:153-176`).
  - Whoever holds a URL can download the export or attachment, or push files into the page, as the member (`web/downloads.py:106-148`, `web/uploads.py:246-399`). No cookie or bearer is needed.
  - The URLs land in the conversation transcript, and from there possibly in shared chats or client logs. Server access logs are redacted (`web/downloads.py:51-63`, `__main__.py:22-28`).
  - Grant revocation is honoured (`web/downloads.py:99`, `db/upload_store.py:119-134`). ALLOWED_SPACES is not re-checked when a download link is opened.
- **Exploit scenario.**
  - A member asks Claude to export a space. The resulting chat, containing the link, is shared or copied into a ticket within 10 minutes. A third party downloads the full space zip with the member's rights.
  - Separately, a prompt-injected page instructs the model to call `create_upload_link` and send the URL somewhere. The holder can then attach arbitrary files to that page as the member.
- **Suggested fix.** For a small team, consider disabling `export_space` or attachment links, or requiring a web session cookie on `/downloads`. Make download links single use and shorter. Set `UPLOAD_RETENTION_MINUTES` to its minimum of 5. Keep `write` off for clients that do not need it.

#### Info notes (1.6)

- **I-9.** The space check runs after a read-only Docmost lookup. For page, attachment, comment and version ids, the server first calls `pages/info` / `files/info` / `comments/info` / `pages/history/info` with the member's token to learn the space, then checks it. Data from a non-allowed space is fetched into memory but discarded, and nothing is returned. No known Docmost side effect follows from these reads. So "enforced before the Docmost call" holds for every call that matters but not literally.
- **I-10.** ALLOWED_SPACES is not a Docmost ACL. It confines the AI client only. Members keep full Docmost UI access. Workspace-level tools are not space-scoped by design:
  - list_labels without a page lists all workspace label names (`tools/labels.py:117`).
  - suggest returns people and groups.
  - list_workspace_members, list_groups and list_invitations are workspace-wide.
  - The admin tools add_group_members, invite_people and change_workspace_role can give people roles in non-allowed spaces indirectly, through groups.
  - check_space_health probes linked pages outside the space and reports "not found" or "in Trash" (`tools/health.py:146-157`).
- **I-11.** ALLOWED_SPACES may use slugs (`tools/spaces.py:23-24`). A slug is mutable in Docmost, so if an allowed space's slug is later freed and reused by another space, that space becomes allowed. Configure space ids, not slugs.
- **I-12.** Some checks are delegated to Docmost and were not verified in this review:
  - `list_pages(parent_page_id=...)` and `get_page_tree(root_page_id=...)` check `space_id` but not that the parent page belongs to it (`tools/read.py:161-165`, `tools/navigate.py:101-112`). They rely on Docmost's `pages/sidebar-pages` filtering by `spaceId`.
  - `add_comment(reply_to_comment_id=...)` relies on Docmost to reject a parent comment from another page (`tools/write.py:722-731`).
- **I-13.** ALLOWED_EMAILS is checked against the email Docmost reports (`members.py:72`), so it is only as strong as Docmost's email-change controls. List only addresses that already exist in Docmost.

---

## 1.4 Outbound network: PASS

- The only outbound HTTP client in `src/` is one `httpx.AsyncClient` with `base_url = DOCMOST_URL + "/api"` and `follow_redirects=False` (`docmost/ce.py:103-109`). Searching `src/` for `httpx`, `AsyncClient`, `urlopen`, `requests`, `aiohttp`, `socket` and `fetch(` found nothing else. The browser `fetch` calls in `web/upload.js:137`, `:185`, `:240` are same-origin and run in the user's browser.
- **Request paths are constants.** The one exception is `files/{quote(attachment_id, safe='')}/{quote(file_name, safe='')}` (`docmost/ce.py:728`). Both parts are percent-encoded with `safe=''`, so neither `/` nor `:` survives and an absolute-URL override of `base_url` is impossible.
- **No URL fetching from user input.**
  - `page_ref` only parses a slug id out of a pasted URL and never fetches it (`tools/read.py:51-63`).
  - `check_space_health` resolves links via `pages/info` on Docmost only (`tools/health.py:146-157`).
  - `docmost/links.py` only rewrites Markdown.
  - Images and attachment URLs are never fetched server-side.
- **No client-metadata fetching.** CIMD and `jwks_uri` are not used by `OAuthProvider`, and `private_key_jwt` is refused at registration. `logo_uri` is ignored.
- **No telemetry.**
  - FastMCP's OpenTelemetry uses the API only. `uv.lock` contains `opentelemetry-api` and no SDK or exporter, so nothing is exported.
  - The FastMCP update check (`check_for_updates`) runs only from the CLI banner (fastmcp `utilities/cli.py:211`, `cli/cli.py:133`). The banner is not used: the server starts via `uvicorn.run(create_app(...))` (`__main__.py:66-75`), and `--tool-catalog` passes `show_banner=False`.
- **Info.**
  - **I-14.** Docmost itself calls GitHub from its version endpoint (noted at `tools/common.py:48-49`). That is Docmost egress, not this sidecar's.
  - **I-15.** httpx `trust_env` defaults to on, so `HTTP(S)_PROXY`, `ALL_PROXY`, `SSL_CERT_FILE` and `.netrc` in the container environment would affect Docmost traffic, which includes member passwords at sign-in. Keep the container environment clean. Optionally set `FASTMCP_CHECK_FOR_UPDATES=off` as defence in depth.
- **Recommendation.** Enforce egress at the network layer: allow the container to reach only Docmost and Postgres.

---

## Unverified items

- Docmost-side checks referenced in I-12 (sidebar-pages parent/space consistency; cross-page parent comments).
- Library behaviour was confirmed by reading `mcp` 2.3.0 and `fastmcp-slim` 4.1.3 source only, not by running anything.
- Host/Origin (DNS-rebinding) protection in FastMCP's `http_app` was not reviewed. It is out of scope for this checklist.
