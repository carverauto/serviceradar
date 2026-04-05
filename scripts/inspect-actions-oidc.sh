#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cosign_common.sh"
trap cosign_cleanup_temp_files EXIT

cosign_require_tool python3
cosign_require_tool jq

token_file="$(cosign_resolve_identity_token_file)"
if [[ -z "${token_file}" ]]; then
  cat >&2 <<'EOF'
error: no OIDC identity token available.
Provide one of:
  SIGSTORE_ID_TOKEN
  SIGSTORE_ID_TOKEN_FILE
  ACTIONS_ID_TOKEN_REQUEST_URL + ACTIONS_ID_TOKEN_REQUEST_TOKEN
EOF
  exit 1
fi

python3 - <<'PY' "${token_file}"
import base64
import json
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("error: token does not look like a JWT")

def decode(segment: str):
    padding = "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment + padding))

print(json.dumps({
    "header": decode(parts[0]),
    "payload": decode(parts[1]),
}, indent=2, sort_keys=True))
PY
