# Deployment runbook: Docmost + MCP sidecar

This directory runs the team wiki and its remote MCP server on one small host
with Docker Compose. The design and decisions are in
[`docs/mcp/BUILD_PLAN.md`](../docs/mcp/BUILD_PLAN.md) (sections 5, 6, 10, 11).

| Host name | Service | Purpose |
|---|---|---|
| `docs.southeastexpeditionmed.com` | `docmost` (port 3000, internal) | Wiki: editor, API, collaboration WebSockets |
| `docs-mcp.southeastexpeditionmed.com` | `docmost-mcp` (port 8000, internal) | Remote MCP server for Claude, OAuth sign-in and consent pages |

Services in `compose.yaml`: `caddy` (TLS, the only service with published
ports: 80, 443/tcp, 443/udp), `docmost` (pinned upstream image), `docmost-mcp`
(our build of `osh-labs/docmost-mcp-remote`, by digest), `postgres` (18; databases
`docmost` and `docmost_mcp`), `redis` (8; AOF on, `noeviction`).

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | All services, networks, volumes, memory limits, healthchecks |
| `Caddyfile` | Two sites, HSTS, upload limits, JSON access logs |
| `.env.example` | Every variable, with comments. Copy to `.env` |
| `postgres-init/10-mcp.sh` | Creates role and database `docmost_mcp` on first init |
| `scripts/smoke.sh` | Post-deploy checks; nonzero exit on failure |
| `scripts/backup.sh` | `pg_dumpall` + storage volume tar, uploaded to S3 |
| `scripts/restore.sh` | Inverse of `backup.sh`, with a confirmation prompt |

## Design notes

- **Networks.** `edge` is a normal bridge (Caddy, Docmost; outbound internet
  for ACME and SMTP). `proxy` is internal with the fixed subnet
  `172.28.10.0/24` (Caddy, Docmost, sidecar). `backend` is internal (Postgres,
  Redis, Docmost, sidecar). The sidecar has no route to the internet; it only
  needs Docmost and Postgres.
- **`DOCMOST_ALLOW_INSECURE_HTTP=true`.** The sidecar calls Docmost at
  `http://docmost:3000` over the internal `proxy` network. That traffic never
  leaves the host, so plain http is acceptable there. Everything public is
  https through Caddy.
- **`FORWARDED_ALLOW_IPS=172.28.10.0/24`.** The sidecar trusts
  `X-Forwarded-For` only from the `proxy` subnet, where Caddy is. Caddy sets
  the header to the address it sees, so a client cannot choose its own address
  for rate limiting. Never set it to `*`. If the subnet in `compose.yaml`
  changes, change this value with it.
- **Upload limits.** `docs.` allows request bodies up to 210 MiB (Docmost
  defaults: 50 MB uploads, 200 MB imports). `docs-mcp.` allows 51 MiB:
  `UPLOAD_MAX_MB=50` plus the 1 MiB of multipart overhead the sidecar accepts.
  Change `UPLOAD_MAX_MB` in `compose.yaml` and `max_size` in the `Caddyfile`
  together.
- **Sidecar hardening.** `read_only`, `tmpfs: /tmp`, `cap_drop: ALL`,
  `no-new-privileges`, as in the upstream compose file.
- **Access logs.** JSON, in the `caddy_logs` volume as `docs-access.log` and
  `mcp-access.log` (on the host:
  `docker volume inspect sem-docmost_caddy_logs -f '{{.Mountpoint}}'`,
  normally `/var/lib/docker/volumes/sem-docmost_caddy_logs/_data`). These are
  the files the fail2ban jail (Phase 4.6) reads. Query strings are dropped on
  both sites. On `docs-mcp.` the token in `/downloads/<token>` and
  `/uploads/<token>` paths is replaced by `REDACTED`, and the `Referer` and
  response `Location` headers (OAuth codes) are removed. Caddy already redacts
  `Authorization`, `Cookie` and `Set-Cookie`.

### Memory limits (estimates)

Sized for a 1 GB instance with a 2 GB swap file. These are estimates from
build plan section 5.3, to be tuned from the measurements at test T-10
(`docker stats` every 10 s under load).

| Service | `mem_limit` | Planned RSS |
|---|---|---|
| docmost | 512m | 300 to 450 MB |
| postgres | 192m (`shared_buffers=64MB`, `max_connections=40`) | 60 to 120 MB |
| docmost-mcp | 192m | 80 to 150 MB |
| caddy | 96m | 20 to 40 MB |
| redis | 96m | 10 to 30 MB |

The limits add up to more than 1 GB on purpose: they are ceilings, not
reservations, and the swap file absorbs short peaks. If a container is
OOM-killed (`docker inspect <container> -f '{{.State.OOMKilled}}'`), raise its
limit or move to the 2 GB bundle (decision D-6).

## Prerequisites

1. Lightsail instance, Ubuntu 24.04, 1 GB (2 GB fallback), static IP.
   Lightsail firewall: 22 (restricted to admin IPs), 80, 443 TCP, 443 UDP.
2. Host hardening (build plan 4.1): sudo user, SSH keys only,
   `PasswordAuthentication no`, unattended-upgrades, UFW allowing 22 (admin
   IPs), 80/tcp, 443/tcp, 443/udp.
3. 2 GB swap file and `vm.swappiness=10`:

   ```sh
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
   sudo mkswap /swapfile && sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf && sudo sysctl --system
   ```

4. Docker Engine and the Compose plugin from Docker's apt repository
   (`docker compose version` must work). Also install `jq` (for `smoke.sh`)
   and the AWS CLI (for backups).
5. Cloudflare: A records for `docs` and `docs-mcp` pointing at the static IP,
   **DNS only (grey cloud)**, so Caddy gets Let's Encrypt certificates itself
   and nothing sits between Anthropic's cloud and the MCP server. If `docs-mcp.`
   is ever proxied, exempt it from Bot Fight Mode and WAF challenges.
6. The sidecar image digest from the `osh-labs/docmost-mcp-remote` build, and
   the S3 bucket and IAM user for backups (Phase 0.4).

## First boot

```sh
# On the host, as the deploy user. The repository is public, so a sparse
# clone of deploy/ is enough (no credentials on the host).
sudo mkdir -p /opt/sem-docmost && sudo chown "$USER" /opt/sem-docmost
cd /opt/sem-docmost
git clone --depth 1 --branch <branch> --filter=blob:none --sparse \
  https://github.com/osh-labs/SEM-docmost.git repo
cd repo && git sparse-checkout set deploy
ln -s /opt/sem-docmost/repo/deploy /opt/sem-docmost/deploy
cd /opt/sem-docmost/deploy
cp .env.example .env && chmod 600 .env
# Generate the four secrets in place (values are not printed):
for k in POSTGRES_PASSWORD MCP_DB_PASSWORD APP_SECRET SECRET_KEY; do
  sed -i "s|^$k=\$|$k=$(openssl rand -hex 32)|" .env
done
# Later updates of the deploy files: cd /opt/sem-docmost/repo && git pull
```

Fill in `.env`:

- `ACME_EMAIL`.
- `DOCMOST_TAG`: see "Choosing the Docmost tag" below.
- `MCP_IMAGE`: `ghcr.io/osh-labs/docmost-mcp-remote@sha256:<digest>`. A tag
  is not accepted by policy; use the digest.
- Secrets: `POSTGRES_PASSWORD`, `MCP_DB_PASSWORD`, `APP_SECRET`,
  `SECRET_KEY` (filled by the loop above; never commit `.env`, the
  repository is public).
- `ALLOWED_EMAILS`: the team's Docmost email addresses, comma-separated.
- Mail (deferred; leave the mail lines commented out until the stack runs;
  Docmost refuses to start with `MAIL_DRIVER=log`). Later, enable
  `compose.mail.yaml` (see `.env.example`). Through Migadu: create the sending mailbox (for example
  `docs@southeastexpeditionmed.com`) in Migadu, check that the domain's
  SPF, DKIM and DMARC records from Migadu's DNS setup page are in
  Cloudflare, and put the mailbox password in `SMTP_PASSWORD`. Test by
  sending yourself a password reset after first boot.
- Backup settings (`BACKUP_*`, `AWS_*`).

Store `SECRET_KEY` (and preferably the whole `.env`) in the team password
manager **now**, before first use. See "SECRET_KEY" below.

Start and check:

```sh
docker compose pull
docker compose up -d
docker compose ps              # postgres, redis, docmost, docmost-mcp: healthy
docker compose logs -f caddy   # watch for "certificate obtained successfully"
scripts/smoke.sh
```

`postgres-init/10-mcp.sh` runs only when the Postgres volume is empty, i.e. on
the very first start. Check it ran:

```sh
docker compose exec postgres psql -U docmost -d postgres -c '\l docmost_mcp'
```

If the database is missing, the volume already existed when the script was
added. On a fresh install with no data, remove the volume and start again:
`docker compose down && docker volume rm sem-docmost_postgres_data`. On an
install with data, create the role and database by hand with the SQL in
`postgres-init/10-mcp.sh`.

### Local test stack (Phase 2.5)

Set `DOCS_HOST=docs.localhost` and `MCP_HOST=docs-mcp.localhost` in `.env`.
Caddy then serves both with its own internal CA (no ACME). Most systems
resolve `*.localhost` to 127.0.0.1. Run the smoke test with
`SMOKE_INSECURE=1 scripts/smoke.sh https://docs.localhost https://docs-mcp.localhost`.
For Claude Code to connect, trust Caddy's root certificate
(`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .`).

## Docmost first-run setup

1. Open `https://docs.southeastexpeditionmed.com`. The first visit shows the
   setup page: create the workspace (name, admin name, admin email, password).
   Do this immediately after first boot; until then anyone who reaches the
   site can claim the workspace.
2. Workspace settings: set the workspace name and, under Security, restrict
   sign-ups as wanted.
3. Create spaces and set space membership (members see only spaces they
   belong to; the MCP sidecar enforces the same rights, because it acts with
   each member's own Docmost session).

## Creating users

1. Settings > Members > Invite members: enter emails and role (Member for most,
   Admin only where needed).
2. With SMTP configured the invitee gets an email. Without mail configured
   nothing is sent (in production the log driver discards mail): open the
   pending invitation's action menu in Settings > Members, copy the invite
   link, and send it to the member directly.
3. Add each member's email to `ALLOWED_EMAILS` in `.env` and apply with
   `docker compose up -d docmost-mcp`. An empty `ALLOWED_EMAILS` lets every
   Docmost user use the connector.
4. Add the member to the right spaces.

## Adding the Claude connector

The connector URL is exactly:

```
https://docs-mcp.southeastexpeditionmed.com/mcp
```

It must match the `resource` in the protected-resource metadata (smoke.sh
checks it).

- **claude.ai / Claude desktop / Claude mobile.** Settings > Connectors > Add
  custom connector, paste the URL. The browser opens the sidecar's sign-in
  page (Docmost email and password), then the consent page, then returns to
  Claude. Tick `read` and `write`; leave `delete` and `admin` off (decision
  D-4: those are for Chris only). Connectors added on claude.ai appear in the
  mobile app. On a Team or Enterprise plan, an owner adds the connector at
  organization level first.
- **Claude Code.**

  ```sh
  claude mcp add --transport http docmost https://docs-mcp.southeastexpeditionmed.com/mcp
  ```

  then run `/mcp` in Claude Code and complete the sign-in.

- **Revoking.** A member revokes grants at
  `https://docs-mcp.southeastexpeditionmed.com/account`. An admin can use the
  sidecar CLI:

  ```sh
  docker compose exec docmost-mcp docmost-mcp-remote admin members
  docker compose exec docmost-mcp docmost-mcp-remote admin grants anna@example.com
  docker compose exec docmost-mcp docmost-mcp-remote admin revoke-member anna@example.com
  docker compose exec docmost-mcp docmost-mcp-remote admin audit --email anna@example.com
  ```

With `RELOGIN_MODE=ask`, members sign in again when their Docmost session
expires (`JWT_TOKEN_EXPIRES_IN`, 90 days by default). Agent-written
@-mentions send Docmost notifications (decision D-7); tell members.

## Verifying with smoke.sh

```sh
scripts/smoke.sh                                   # production defaults
scripts/smoke.sh https://docs.example https://docs-mcp.example
```

Checks: `GET /api/health` on `docs.` is 200; `GET /healthz` on `docs-mcp.` is
200; `POST /mcp` without a token is 401 with a `WWW-Authenticate` header that
points to the protected-resource metadata; the metadata's `resource` equals
`https://docs-mcp.southeastexpeditionmed.com/mcp` (override with
`EXPECTED_RESOURCE`). Each check prints PASS or FAIL; the exit status is 1 if
any failed. Needs `curl` and `jq` or `python3`.

## Upgrades

Always back up first (`scripts/backup.sh`). Neither Docmost nor the sidecar
supports going back to an older version after a schema upgrade; roll back by
restoring the backup with the old image.

### Choosing the Docmost tag

1. Read the release list and notes: <https://github.com/docmost/docmost/releases>.
   Note breaking changes and anything touching `pages/update`, `search` or
   comments (the sidecar depends on them).
2. Confirm the image tag exists: <https://hub.docker.com/r/docmost/docmost/tags>.
   Docker Hub tags have no leading `v` (GitHub `v0.97.0` is image `0.97.0`).
   Never use `latest`.
3. Check the sidecar's README "Supported Docmost versions" for the new tag.

### Bumping Docmost

1. On a local stack, set the new `DOCMOST_TAG`, start it, and rerun T-03, T-05
   and T-06 from the build plan.
2. On the host: edit `DOCMOST_TAG` in `.env`, then

   ```sh
   scripts/backup.sh
   docker compose pull docmost
   docker compose up -d docmost
   docker compose logs -f docmost   # migrations run on start
   scripts/smoke.sh
   ```

### Bumping the sidecar

1. In `osh-labs/docmost-mcp-remote`: merge upstream, review the diff and the
   upstream CHANGELOG "Upgrade notes", build, and note the new image digest
   (`docker buildx imagetools inspect ghcr.io/osh-labs/docmost-mcp-remote:<tag>`).
2. Rerun the Phase 3 subset locally.
3. On the host: set `MCP_IMAGE=ghcr.io/osh-labs/docmost-mcp-remote@sha256:<new digest>`
   in `.env`, then

   ```sh
   scripts/backup.sh
   docker compose pull docmost-mcp
   docker compose up -d docmost-mcp
   docker compose exec docmost-mcp docmost-mcp-remote admin migrate   # shows schema revision
   scripts/smoke.sh
   ```

Caddy, Postgres and Redis follow the tags in `.env` (`CADDY_TAG`,
`POSTGRES_TAG`, `REDIS_TAG`); `docker compose pull && docker compose up -d`
picks up their patch releases. A Postgres **major** upgrade (18 to 19) needs a
dump and restore; do not just change the tag.

## Backups and restore

### Backup

`scripts/backup.sh` reads `.env` and:

1. Runs `pg_dumpall --clean --if-exists` in the `postgres` container (both
   databases and the roles), gzipped.
2. Tars the Docmost storage volume (`/app/data/storage`) from the `docmost`
   container.
3. Writes `SHA256SUMS` and uploads all three to
   `s3://$BACKUP_S3_BUCKET/$BACKUP_S3_PREFIX/YYYY/MM/DD/<UTC timestamp>/`.
4. Optionally uploads `.env` encrypted with `age` to `BACKUP_ENV_S3_URI`
   (a separate destination; build plan 6.2).
5. Deletes local copies in `BACKUP_DIR` older than
   `BACKUP_LOCAL_RETENTION_DAYS`.

Redis is not backed up (queues and collaboration cache only). Caddy
certificates are re-issued automatically.

Nightly cron (root, because the backup directory and Docker need it):

```cron
15 3 * * * /opt/sem-docmost/deploy/scripts/backup.sh >>/var/log/sem-docmost-backup.log 2>&1
```

Use `/etc/cron.d` (as installed on 2026-11-10):

```sh
echo '15 3 * * * root /opt/sem-docmost/deploy/scripts/backup.sh >>/var/log/sem-docmost-backup.log 2>&1' \
  | sudo tee /etc/cron.d/sem-docmost-backup && sudo chmod 644 /etc/cron.d/sem-docmost-backup
```

S3 bucket settings (as set up for `sem-docmost-backups-01`, `us-east-1`):
Block all public access on, Versioning on, SSE-S3, and a lifecycle rule
that expires current versions after 90 days and deletes noncurrent versions
30 days after they become noncurrent. Versioning protects against a
compromised host overwriting the backups, because the host's key cannot
delete versions.

IAM user `sem-docmost-backup`, no console access, one inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BackupObjectsOnly",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::<bucket>/sem-docmost/*",
        "arn:aws:s3:::<bucket>/sem-docmost-env/*"
      ]
    }
  ]
}
```

Its access key goes into `.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).

The `.env` copy is encrypted with `age`. Generate the key pair once with
`age-keygen` (it prints the keys and writes nothing), keep the whole output
in the password manager, and put only the public `age1...` key in
`BACKUP_AGE_RECIPIENT`. The private key never stays on the production host.

The database dump contains the sidecar's encrypted Docmost sessions and page
snapshots. They are only readable with `SECRET_KEY`, which is why `.env` is
kept separately from the dumps.

### Restore

```sh
scripts/restore.sh s3://<bucket>/sem-docmost/2026/11/09/20261109T031500Z
# or a local directory with postgres.sql.gz, storage.tar.gz, SHA256SUMS
```

The script verifies checksums, prints what it will destroy, and asks you to
type `RESTORE`. It then stops Caddy, Docmost and the sidecar, replaces both
databases (and resets the `docmost` and `docmost_mcp` role passwords to the
backup's), replaces the storage volume, flushes Redis and starts everything.
**Everything written after the backup is lost.**

Use the `.env` that belongs to the backup: the restored role passwords must
match `POSTGRES_PASSWORD` and `MCP_DB_PASSWORD`, Docmost sessions need the
same `APP_SECRET`, and the sidecar data needs the same `SECRET_KEY`.

On a new host: install as in "First boot", put the matching `.env` in place,
then run `restore.sh` (it starts Postgres and Redis itself). Afterwards run
`scripts/smoke.sh`, open a few pages and attachments, and check that a
member's existing MCP grant still works (build plan 6.3). Record the restore
time in `docs/mcp/TEST_REPORT.md`.

### Restore test on a temporary instance

Done once on 2026-11-10; repeat after major upgrades. It works from a
Windows PC (no `age` needed locally), because the `.env` copy is decrypted on
the temporary host:

1. Create a $7 Lightsail instance with the same launch script plus
   `hostnamectl set-hostname sem-docs-restore`. Firewall: SSH from your IP
   only; no static IP; no DNS changes.
2. Sparse-clone `deploy/` as in "First boot".
3. Download `env.age` from `sem-docmost-env/...` in the S3 console and copy
   it to `/opt/sem-docmost/deploy/` (`scp -i <key.pem> env.age
   ubuntu@<ip>:/opt/sem-docmost/deploy/` in PowerShell).
4. `sudo apt-get install -y age`, paste the private key into
   `/tmp/age-key.txt`, then
   `age -d -i /tmp/age-key.txt -o .env env.age && chmod 600 .env && shred -u /tmp/age-key.txt`.
5. Set `DOCS_HOST=docs.localhost` and `MCP_HOST=docs-mcp.localhost` in that
   `.env`, so the copy uses Caddy's internal CA and leaves the real host
   names alone.
6. Check `hostname` prints `sem-docs-restore`, then run
   `sudo scripts/restore.sh s3://<bucket>/sem-docmost/YYYY/MM/DD/<ts>`.
7. Verify: `docker compose ps` all healthy;
   `docker compose exec docmost-mcp docmost-mcp-remote admin members` lists
   the members and their grants (proves `SECRET_KEY` matches); through
   `ssh -L 443:127.0.0.1:443 ubuntu@<ip>`, sign in at https://docs.localhost
   and check spaces, pages and comments.
8. Delete the instance: its `.env` holds the production secrets and the S3
   key.

## SECRET_KEY

`SECRET_KEY` encrypts the members' stored Docmost sessions and the page
snapshots in the `docmost_mcp` database, and signs the sidecar's cookies.

- Keep a copy in the **team password manager**, plus the encrypted `.env`
  backup. It is not in git and not in the database dumps.
- **Losing it** signs every member out of the connector (they must add it
  again or sign in again) and makes stored snapshots unreadable.
- **Leaking it** together with a database dump exposes members' Docmost
  sessions. If it leaks, rotate it and revoke all grants.

### Rotating SECRET_KEY

1. In `.env`, set `SECRET_KEY_PREVIOUS` to the current key and `SECRET_KEY` to
   a new `openssl rand -hex 32` value.
2. `docker compose up -d docmost-mcp`
3. `docker compose exec docmost-mcp docmost-mcp-remote admin rotate-key`
4. Clear `SECRET_KEY_PREVIOUS`, `docker compose up -d docmost-mcp` again.
5. Update the password manager and the encrypted `.env` backup.

`APP_SECRET` (Docmost) has no rotation path; changing it signs every Docmost
user out.

## Changing database passwords

The init script only runs on an empty volume, so changing `MCP_DB_PASSWORD`
or `POSTGRES_PASSWORD` in `.env` alone breaks the connection. Change the role
first, then `.env`, then restart:

```sh
docker compose exec postgres psql -U docmost -d postgres \
  -c "ALTER ROLE docmost_mcp PASSWORD '<new hex value>'"
# edit MCP_DB_PASSWORD in .env
docker compose up -d docmost-mcp
```

## Useful commands

```sh
docker compose ps
docker compose logs -f --tail=100 docmost docmost-mcp
docker stats --no-stream
docker compose exec postgres psql -U docmost -d docmost
docker compose exec docmost-mcp docmost-mcp-remote admin audit
sudo tail -f /var/lib/docker/volumes/sem-docmost_caddy_logs/_data/mcp-access.log | jq .
```

Run `docker compose` commands from this directory (or pass
`-f deploy/compose.yaml`) so `.env` is picked up. The Compose project name is
fixed to `sem-docmost`, so volume names are `sem-docmost_<name>`.
