#!/usr/bin/env bash
# Creates the docmost_mcp role and database for the MCP sidecar.
#
# Run by the postgres image entrypoint from /docker-entrypoint-initdb.d, and
# ONLY when the data volume is empty (first initialisation). It does not run
# on later starts, so changing MCP_DB_PASSWORD in .env afterwards has no
# effect here; change the password with ALTER ROLE instead (see README).
#
# It is a .sh script rather than .sql because it reads the password from the
# MCP_DB_PASSWORD environment variable. The password is passed to psql as a
# variable and quoted by psql (:'mcp_password'), not spliced into SQL text.
set -euo pipefail

if [[ -z "${MCP_DB_PASSWORD:-}" ]]; then
	echo "10-mcp.sh: MCP_DB_PASSWORD is not set; refusing to create docmost_mcp" >&2
	exit 1
fi

psql -v ON_ERROR_STOP=1 \
	-v mcp_password="$MCP_DB_PASSWORD" \
	--username "$POSTGRES_USER" \
	--dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE docmost_mcp LOGIN PASSWORD :'mcp_password';
CREATE DATABASE docmost_mcp OWNER docmost_mcp;
-- Each role reaches only its own database.
REVOKE ALL ON DATABASE docmost_mcp FROM PUBLIC;
REVOKE ALL ON DATABASE docmost FROM PUBLIC;
SQL

echo "10-mcp.sh: created role and database docmost_mcp"
