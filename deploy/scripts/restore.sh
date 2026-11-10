#!/usr/bin/env bash
# Restore a backup made by backup.sh. DESTRUCTIVE: replaces both databases
# (docmost, docmost_mcp), their roles' passwords, and the whole Docmost
# storage volume.
#
# Usage:
#   scripts/restore.sh [--yes] SOURCE
#
# SOURCE is either the S3 folder of one backup run, for example
#   s3://my-bucket/sem-docmost/2026/11/09/20261109T031500Z
# or a local directory holding postgres.sql.gz, storage.tar.gz, SHA256SUMS.
# --yes skips the confirmation prompt (for scripted restore tests only).
#
# Before running:
#   - deploy/.env must be the .env that belongs to this backup (restore it
#     from the encrypted copy or the password manager). The dump resets the
#     docmost and docmost_mcp role passwords to the ones in the backup, the
#     sidecar can only read its stored sessions and snapshots with the same
#     SECRET_KEY, and Docmost sessions are signed with APP_SECRET.
#   - On a new host, run "docker compose up -d postgres redis" once first so
#     the volumes exist, or let this script do it.
#
# Configuration (AWS credentials, BACKUP_DIR) is read from deploy/.env or
# BACKUP_ENV_FILE, parsed as KEY=VALUE lines, not executed.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${BACKUP_ENV_FILE:-$DEPLOY_DIR/.env}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() {
	log "ERROR: $*" >&2
	exit 1
}
usage() {
	sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 2
}

env_get() {
	local key="$1" default="${2:-}" line value
	if [[ -n "${!key:-}" ]]; then
		printf '%s' "${!key}"
		return
	fi
	line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)"
	value="${line#*=}"
	value="${value%$'\r'}"
	if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
		value="${BASH_REMATCH[1]}"
	fi
	printf '%s' "${value:-$default}"
}

ASSUME_YES=0
SOURCE=""
while (($# > 0)); do
	case "$1" in
	--yes) ASSUME_YES=1 ;;
	-h | --help) usage ;;
	-*) die "unknown option: $1" ;;
	*)
		[[ -z "$SOURCE" ]] || die "only one SOURCE may be given"
		SOURCE="$1"
		;;
	esac
	shift
done
[[ -n "$SOURCE" ]] || usage

[[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"
for cmd in docker gzip sha256sum; do
	command -v "$cmd" >/dev/null || die "$cmd is not installed"
done

COMPOSE=(docker compose -f "$DEPLOY_DIR/compose.yaml" --env-file "$ENV_FILE")
BACKUP_DIR="$(env_get BACKUP_DIR /var/backups/sem-docmost)"

# 1. Get the files.
if [[ "$SOURCE" == s3://* ]]; then
	command -v aws >/dev/null || die "aws is not installed"
	for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
		value="$(env_get "$key")"
		if [[ -n "$value" ]]; then
			export "$key=$value"
		fi
	done
	SOURCE="${SOURCE%/}"
	SRC_DIR="$BACKUP_DIR/restore-$(date -u +%Y%m%dT%H%M%SZ)"
	mkdir -p "$SRC_DIR"
	log "downloading $SOURCE/ to $SRC_DIR"
	for f in SHA256SUMS postgres.sql.gz storage.tar.gz; do
		aws s3 cp --only-show-errors "$SOURCE/$f" "$SRC_DIR/$f"
	done
else
	SRC_DIR="$(cd "$SOURCE" && pwd)" || die "no such directory: $SOURCE"
fi

for f in SHA256SUMS postgres.sql.gz storage.tar.gz; do
	[[ -s "$SRC_DIR/$f" ]] || die "missing or empty: $SRC_DIR/$f"
done
log "verifying checksums"
(cd "$SRC_DIR" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $SRC_DIR"

# 2. Confirm.
cat <<EOF

  WARNING: DESTRUCTIVE RESTORE

  Source:   $SOURCE
  Project:  $DEPLOY_DIR/compose.yaml
  Env file: $ENV_FILE

  This will:
    - stop caddy, docmost and docmost-mcp (the site goes offline)
    - DROP and recreate the docmost and docmost_mcp databases from the dump
    - reset the docmost and docmost_mcp role passwords to the backup's
    - DELETE everything in the Docmost storage volume and unpack the backup
    - FLUSH Redis (queues and collaboration cache)
    - start everything again

  Everything written since the backup was taken is lost. If the current
  data matters, run scripts/backup.sh first.

  The env file must be the one that belongs to this backup (same
  POSTGRES_PASSWORD, MCP_DB_PASSWORD, APP_SECRET and SECRET_KEY).

EOF
if ((ASSUME_YES == 0)); then
	[[ -t 0 ]] || die "not a terminal; pass --yes to restore without a prompt"
	read -r -p "Type RESTORE to continue: " answer
	[[ "$answer" == "RESTORE" ]] || die "aborted"
fi

# 3. Data services up, application services down.
log "starting postgres and redis"
"${COMPOSE[@]}" up -d --wait postgres redis
log "stopping caddy, docmost-mcp, docmost"
"${COMPOSE[@]}" stop caddy docmost-mcp docmost

# 4. Postgres. The dump was made with --clean --if-exists, so it drops and
# recreates each database. Two errors are expected and harmless: the dump
# tries to drop and create the role we are connected as ("docmost").
log "restoring Postgres"
PSQL_LOG="$SRC_DIR/psql-restore.log"
gzip -dc "$SRC_DIR/postgres.sql.gz" \
	| "${COMPOSE[@]}" exec -T postgres psql --username=docmost --dbname=postgres \
		--quiet --no-psqlrc -v ON_ERROR_STOP=0 >"$PSQL_LOG" 2>&1 || true
unexpected="$(grep -E '(ERROR|FATAL):' "$PSQL_LOG" \
	| grep -vE 'current user cannot be dropped|role "docmost" already exists' || true)"
if [[ -n "$unexpected" ]]; then
	printf '%s\n' "$unexpected" | head -n 20 >&2
	die "Postgres restore reported errors (full log: $PSQL_LOG); services left stopped"
fi
"${COMPOSE[@]}" exec -T postgres psql --username=docmost --dbname=postgres -tAc \
	"SELECT datname FROM pg_database WHERE datname IN ('docmost','docmost_mcp') ORDER BY 1" \
	| tr -d '\r' | paste -sd, - | grep -qx 'docmost,docmost_mcp' \
	|| die "databases docmost and docmost_mcp not both present after restore"

# 5. Storage volume. Runs as the image's "node" user, which owns the volume.
log "restoring Docmost storage volume"
"${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh docmost -c \
	'find /app/data/storage -mindepth 1 -delete && tar -C /app/data/storage -xzf -' \
	<"$SRC_DIR/storage.tar.gz"

# 6. Redis.
log "flushing Redis"
"${COMPOSE[@]}" exec -T redis redis-cli FLUSHALL >/dev/null

# 7. Start everything.
log "starting all services"
"${COMPOSE[@]}" up -d --wait

log "restore complete. Next: scripts/smoke.sh, then sign in and check pages,"
log "attachments and one member's MCP connector (build plan 6.3)."
