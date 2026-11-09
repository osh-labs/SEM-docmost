# Test Report: Docmost + MCP Sidecar (Phase 3)

Environment: Lightsail 1 GB (Ubuntu 24.04, 2 GB swap), `us-east` region. Docmost `0.97.0`. Sidecar `ghcr.io/osh-labs/docmost-mcp-remote@sha256:e8313e822529a0f9144003aee2d635487563e959919cfd76788ff6874b636225` (fork commit `8804fe4`). Postgres 18, Redis 8, Caddy 2.11.

Results marked "reported" were run by Chris on the live host and relayed in the build session. The CI results come from the fork's GitHub Actions.

## 1. Pre-deployment (CI)

| Check | Result | Evidence |
|---|---|---|
| Unit tests (Python 3.12, 3.13) | Pass | Fork CI run 2 on PR #2 |
| Integration tests vs Docmost 0.80.1, 0.96.0, 0.97.0, latest | Pass | Same run; 4 integration jobs |
| Container smoke test and Trivy scan | Pass after the base image update (`b90e063`) | Same run, `docker` job |
| Dependency audit (pip-audit) | Pass | Same run, `audit` job |

## 2. First boot (2026-11-09)

| Step | Result | Note |
|---|---|---|
| `docker compose up` | Failed on the first attempt, then passed | Docmost 0.97 refuses `MAIL_DRIVER=log` at startup. The mail settings moved to the optional `compose.mail.yaml` (SEM-docmost `4a93d2c`) |
| All containers healthy | Pass (reported) | |
| `scripts/smoke.sh` | Pass (reported) | |
| Workspace claimed right after boot | Done (reported) | |

## 3. Memory at idle, after first boot

| Container | RSS | Limit |
|---|---|---|
| docmost | 259 MiB | 512 MiB |
| postgres | 69 MiB | 192 MiB |
| docmost-mcp | 58 MiB | 192 MiB |
| caddy | 32 MiB | 96 MiB |
| redis | 6 MiB | 96 MiB |
| Host | 694 MB used of 909 MB, 214 MB available; swap 493 MB of 2047 MB in use | |

Assessment: all containers are within their limits. The swap in use is mostly pages pushed out during image pulls and migrations. The 1 GB versus 2 GB decision rests on the swap-in rate under load (T-10), not on idle use.

## 4. Functional tests

| Test | Result | Note |
|---|---|---|
| T-01 Sign-in and consent (claude.ai connector) | Pass (reported) | OAuth through the sidecar login, `read` + `write` granted |
| Claude mobile sees the connector | Pass (reported) | |
| T-02 Permission isolation with two concurrent members | Pending | Planned: second Docmost user through a personal token in Claude Code while the claude.ai connector stays signed in as Chris; check both orders |
| T-03 Create and append | Pass (reported) | |
| T-04 Live-edit conflict | Pass (reported) | Append while the page was open in the editor |
| T-05 Markdown fidelity | Pending | |
| T-06 Comments | Pass (reported) | |
| T-07 Scopes (no `write` grant) | Pending | |
| T-08 Revocation and expiry | Pending | |
| T-09 Login throttle | Pending | |
| T-10 Memory under load | Pending | Watch `vmstat` `si`/`so` and `docker stats` |
| T-11 Output caps | Pending | |
| T-12 Audit log | Pending | `docker compose exec docmost-mcp docmost-mcp-remote admin audit` |
