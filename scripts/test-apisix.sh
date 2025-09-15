#!/usr/bin/env bash
set -euo pipefail

# Simple end-to-end test of APISIX integration.
# Requires: docker-compose up core web apisix (with apisix profile) and RS256 configured in core.json.

API="http://localhost"
CORE="http://localhost:8090"

echo "[INFO] Checking core discovery and JWKS..."
curl -fsS "$CORE/.well-known/openid-configuration" | jq . >/dev/null
curl -fsS "$CORE/auth/jwks.json" | jq . >/dev/null

echo "[INFO] Logging in via core local auth (admin/password from your config)..."
USERNAME=${USERNAME:-admin}
PASSWORD=${PASSWORD:-password}
TOKEN=$(curl -fsS -X POST "$CORE/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" | jq -r .access_token)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "[ERROR] Failed to obtain access token. Check local_users and RS256 config." >&2
  exit 1
fi

echo "[INFO] Calling protected API via APISIX with Bearer token..."
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/status" | jq . >/dev/null
echo "[SUCCESS] /api/status succeeded through APISIX."

echo "[INFO] Checking web UI routing through APISIX..."
curl -fsS "$API/" >/dev/null
echo "[SUCCESS] Web UI routed through APISIX."

echo "[DONE] APISIX integration test completed."
