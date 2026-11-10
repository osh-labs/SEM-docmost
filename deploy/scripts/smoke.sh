#!/usr/bin/env bash
# Smoke test for the public Docmost + MCP sidecar endpoints.
#
# Usage:
#   scripts/smoke.sh [DOCS_URL] [MCP_URL]
#
# Defaults (also settable through the environment):
#   DOCS_URL           https://docs.southeastexpeditionmed.com
#   MCP_URL            https://docs-mcp.southeastexpeditionmed.com
#   EXPECTED_RESOURCE  $MCP_URL/mcp
#   SMOKE_INSECURE=1   accept an untrusted certificate (local stack with
#                      Caddy's internal CA); never use against production.
#
# Exit status is 0 when every check passes, 1 otherwise.
set -euo pipefail

DOCS_URL="${1:-${DOCS_URL:-https://docs.southeastexpeditionmed.com}}"
MCP_URL="${2:-${MCP_URL:-https://docs-mcp.southeastexpeditionmed.com}}"
DOCS_URL="${DOCS_URL%/}"
MCP_URL="${MCP_URL%/}"
EXPECTED_RESOURCE="${EXPECTED_RESOURCE:-$MCP_URL/mcp}"

CURL=(curl -sS --max-time 15)
if [[ "${SMOKE_INSECURE:-0}" == "1" ]]; then
	CURL+=(-k)
fi

command -v curl >/dev/null || {
	echo "FAIL: curl is not installed" >&2
	exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
	printf 'FAIL  %s\n' "$1"
	if [[ -n "${2:-}" ]]; then
		printf '      %s\n' "$2"
	fi
	failures=$((failures + 1))
}

# http_status METHOD URL [extra curl args...]
# Prints the status code; headers go to $TMP/headers, body to $TMP/body.
http_status() {
	local method="$1" url="$2"
	shift 2
	local code
	rm -f "$TMP/headers" "$TMP/body" "$TMP/curl.err"
	# On a connection error curl still prints 000 for %{http_code}.
	code="$("${CURL[@]}" -X "$method" -D "$TMP/headers" -o "$TMP/body" \
		-w '%{http_code}' "$@" "$url" 2>"$TMP/curl.err")" || true
	echo "${code:-000}"
}

curl_error() {
	head -c 300 "$TMP/curl.err" 2>/dev/null | tr '\n' ' '
}

echo "Docs: $DOCS_URL"
echo "MCP:  $MCP_URL"
echo

# 1. Docmost health (pings Postgres and Redis).
code="$(http_status GET "$DOCS_URL/api/health")"
if [[ "$code" == "200" ]]; then
	pass "GET $DOCS_URL/api/health -> 200"
else
	fail "GET $DOCS_URL/api/health -> $code (want 200)" "$(curl_error)"
fi

# 2. Sidecar health.
code="$(http_status GET "$MCP_URL/healthz")"
if [[ "$code" == "200" ]]; then
	pass "GET $MCP_URL/healthz -> 200"
else
	fail "GET $MCP_URL/healthz -> $code (want 200)" "$(curl_error)"
fi

# 3. MCP endpoint without a token: 401 and a WWW-Authenticate header that
#    points to the protected-resource metadata.
init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
code="$(http_status POST "$MCP_URL/mcp" \
	-H 'Content-Type: application/json' \
	-H 'Accept: application/json, text/event-stream' \
	--data "$init_body")"
www_auth="$(grep -i '^www-authenticate:' "$TMP/headers" 2>/dev/null | head -n1 | tr -d '\r' || true)"
if [[ "$code" == "401" ]]; then
	pass "POST $MCP_URL/mcp without token -> 401"
else
	fail "POST $MCP_URL/mcp without token -> $code (want 401)" "$(curl_error)"
fi
if [[ -n "$www_auth" ]]; then
	pass "WWW-Authenticate header present"
	if [[ "$www_auth" == *oauth-protected-resource* ]]; then
		pass "WWW-Authenticate points to protected-resource metadata"
	else
		fail "WWW-Authenticate does not mention oauth-protected-resource" "$www_auth"
	fi
else
	fail "WWW-Authenticate header missing on POST /mcp"
fi

# 4. Protected-resource metadata: resource must equal the URL entered in Claude.
code="$(http_status GET "$MCP_URL/.well-known/oauth-protected-resource/mcp")"
if [[ "$code" != "200" ]]; then
	fail "GET $MCP_URL/.well-known/oauth-protected-resource/mcp -> $code (want 200)" "$(curl_error)"
else
	if command -v jq >/dev/null; then
		resource="$(jq -r '.resource // empty' "$TMP/body" 2>/dev/null || true)"
	elif command -v python3 >/dev/null; then
		resource="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("resource",""))' "$TMP/body" 2>/dev/null || true)"
	else
		resource=""
		fail "neither jq nor python3 is installed; cannot parse metadata"
	fi
	if [[ "$resource" == "$EXPECTED_RESOURCE" ]]; then
		pass "protected-resource metadata resource == $EXPECTED_RESOURCE"
	else
		fail "protected-resource metadata resource is '${resource}'" "want $EXPECTED_RESOURCE"
	fi
fi

echo
if ((failures > 0)); then
	echo "RESULT: FAIL ($failures check(s) failed)"
	exit 1
fi
echo "RESULT: PASS"
