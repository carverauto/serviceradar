#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

cosign_require_tool python3

token_source="none"
if [[ -n "${SIGSTORE_ID_TOKEN_FILE:-}" ]]; then
  token_source="sigstore_id_token_file"
elif [[ -n "${SIGSTORE_ID_TOKEN:-}" ]]; then
  token_source="sigstore_id_token"
elif [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  token_source="actions_runner_request"
fi

error_message=""
token_file=""
token_error_file="$(mktemp)"
cosign_register_temp_file "${token_error_file}"

if token_file="$(cosign_resolve_identity_token_file 2>"${token_error_file}")"; then
  if [[ -z "${token_file}" ]]; then
    error_message="no OIDC identity token available"
  fi
else
  error_message="$(tr '\n' ' ' <"${token_error_file}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
fi

if [[ -z "${error_message}" && ! -s "${token_file}" ]]; then
  error_message="resolved token file is empty"
fi

python3 - <<'PY' "${token_file}" "${token_source}" "${error_message}"
import base64
import json
import os
import sys
from pathlib import Path

token_path = sys.argv[1]
token_source = sys.argv[2]
error_message = sys.argv[3]

def decode(segment: str):
    padding = "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment + padding))

result = {
    "ok": False,
    "requested_audience": None,
    "token_source": token_source,
    "environment": {
        "has_sigstore_id_token": bool(os.environ.get("SIGSTORE_ID_TOKEN")),
        "has_sigstore_id_token_file": bool(os.environ.get("SIGSTORE_ID_TOKEN_FILE")),
        "has_actions_id_token_request_url": bool(os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")),
        "has_actions_id_token_request_token": bool(os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")),
    },
}
result["requested_audience"] = (
    os.environ.get("SIGSTORE_OIDC_AUDIENCE")
    or os.environ.get("SIGSTORE_OIDC_CLIENT_ID")
    or "sigstore"
)

if error_message:
    result["error"] = error_message
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0)

token = Path(token_path).read_text(encoding="utf-8").strip()
parts = token.split(".")
if len(parts) != 3:
    result["error"] = "token does not look like a JWT"
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0)

result["ok"] = True
result["header"] = decode(parts[0])
result["payload"] = decode(parts[1])
print(json.dumps(result, indent=2, sort_keys=True))
PY
