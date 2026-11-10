#!/usr/bin/env bash
# Nightly backup: Postgres (both databases, with roles) and the Docmost
# storage volume, uploaded to S3 under date-based keys.
#
# Usage:
#   scripts/backup.sh
#
# Configuration is read from deploy/.env (override with BACKUP_ENV_FILE); see
# the "Backups" block in .env.example. The file is parsed as KEY=VALUE lines,
# not executed.
#
# Writes, per run:
#   $BACKUP_DIR/<ts>/postgres.sql.gz   pg_dumpall --clean --if-exists
#   $BACKUP_DIR/<ts>/storage.tar.gz    contents of /app/data/storage
#   $BACKUP_DIR/<ts>/SHA256SUMS
# and uploads them to
#   s3://$BACKUP_S3_BUCKET/$BACKUP_S3_PREFIX/YYYY/MM/DD/<ts>/
# where <ts> is the UTC time of the run, e.g. 20261109T031500Z.
#
# Not backed up: Redis (queues and collaboration cache only) and Caddy's
# certificates (re-issued automatically). The .env file holds the secrets the
# restored data needs; it is uploaded only if BACKUP_AGE_RECIPIENT and
# BACKUP_ENV_S3_URI are set, encrypted with age, to a separate destination.
#
# The database dump and the storage archive are taken a few seconds apart
# while Docmost is running; an attachment uploaded in between may be present
# in one and not the other.
#
# Cron example (root crontab, 03:15 UTC):
#   15 3 * * * /opt/sem-docmost/deploy/scripts/backup.sh >>/var/log/sem-docmost-backup.log 2>&1
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

# env_get KEY [DEFAULT]: value of KEY from $ENV_FILE (last occurrence),
# with one level of surrounding quotes removed. The environment wins.
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

[[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"
for cmd in docker aws gzip sha256sum; do
	command -v "$cmd" >/dev/null || die "$cmd is not installed"
done

BUCKET="$(env_get BACKUP_S3_BUCKET)"
PREFIX="$(env_get BACKUP_S3_PREFIX sem-docmost)"
PREFIX="${PREFIX%/}"
STORAGE_CLASS="$(env_get BACKUP_S3_STORAGE_CLASS STANDARD)"
BACKUP_DIR="$(env_get BACKUP_DIR /var/backups/sem-docmost)"
RETENTION_DAYS="$(env_get BACKUP_LOCAL_RETENTION_DAYS 7)"
AGE_RECIPIENT="$(env_get BACKUP_AGE_RECIPIENT)"
ENV_S3_URI="$(env_get BACKUP_ENV_S3_URI)"
ENV_S3_URI="${ENV_S3_URI%/}"

[[ -n "$BUCKET" ]] || die "BACKUP_S3_BUCKET is not set in $ENV_FILE"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_LOCAL_RETENTION_DAYS must be a whole number"

# AWS credentials: from the env file if given, else the CLI's own chain.
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
	value="$(env_get "$key")"
	if [[ -n "$value" ]]; then
		export "$key=$value"
	fi
done

COMPOSE=(docker compose -f "$DEPLOY_DIR/compose.yaml" --env-file "$ENV_FILE")

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DATE_PATH="$(date -u +%Y/%m/%d)"
WORK="$BACKUP_DIR/$TS"
DEST="s3://$BUCKET/$PREFIX/$DATE_PATH/$TS"

mkdir -p "$WORK"
cleanup_partial() {
	local status=$?
	if ((status != 0)); then
		log "backup failed; removing partial $WORK"
		rm -rf "$WORK"
	fi
}
trap cleanup_partial EXIT

log "dumping Postgres (pg_dumpall)"
"${COMPOSE[@]}" exec -T postgres \
	pg_dumpall --username=docmost --clean --if-exists \
	| gzip -6 >"$WORK/postgres.sql.gz"
gzip -t "$WORK/postgres.sql.gz"
# A complete dump ends with this line; a truncated one does not.
gzip -dc "$WORK/postgres.sql.gz" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete' \
	|| die "pg_dumpall output looks incomplete"

log "archiving Docmost storage volume"
# GNU tar exits 1 when a file changed while it was read (live system); accept
# that, fail on anything worse. $rc expands inside the container.
# shellcheck disable=SC2016
"${COMPOSE[@]}" exec -T docmost sh -c \
	'tar -C /app/data/storage --warning=no-file-changed -czf - .; rc=$?; [ "$rc" -le 1 ]' \
	>"$WORK/storage.tar.gz"
gzip -t "$WORK/storage.tar.gz"

(cd "$WORK" && sha256sum postgres.sql.gz storage.tar.gz >SHA256SUMS)

log "uploading to $DEST/"
for f in postgres.sql.gz storage.tar.gz SHA256SUMS; do
	aws s3 cp --only-show-errors --storage-class "$STORAGE_CLASS" \
		"$WORK/$f" "$DEST/$f"
done

if [[ -n "$AGE_RECIPIENT" && -n "$ENV_S3_URI" ]]; then
	command -v age >/dev/null || die "BACKUP_AGE_RECIPIENT is set but age is not installed"
	log "uploading encrypted .env to $ENV_S3_URI/"
	age -r "$AGE_RECIPIENT" -o "$WORK/env.age" "$ENV_FILE"
	aws s3 cp --only-show-errors "$WORK/env.age" "$ENV_S3_URI/$DATE_PATH/$TS/env.age"
	rm -f "$WORK/env.age"
elif [[ -n "$AGE_RECIPIENT" || -n "$ENV_S3_URI" ]]; then
	log "WARNING: set both BACKUP_AGE_RECIPIENT and BACKUP_ENV_S3_URI to upload .env; skipped"
fi

log "removing local backups older than $RETENTION_DAYS days from $BACKUP_DIR"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9][0-1][0-9][0-3][0-9]T*Z' \
	-mtime +"$RETENTION_DAYS" -exec rm -rf {} +

log "done: $DEST/"
