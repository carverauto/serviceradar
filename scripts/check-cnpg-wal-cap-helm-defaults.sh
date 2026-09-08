#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/serviceradar"

if [[ -n "${HELM_BIN:-}" ]]; then
  HELM_CMD=("${HELM_BIN}")
elif command -v helm >/dev/null 2>&1; then
  HELM_CMD=(helm)
else
  HELM_CMD=("${ROOT_DIR}/scripts/run-helm.sh")
fi

tmp_root="${ROOT_DIR}/.helm-cnpg-wal-cap-check"
mkdir -p "${tmp_root}"
tmpdir="$(mktemp -d "${tmp_root}/run.XXXXXXXX")"
trap 'rm -rf "${tmpdir}"; rmdir "${tmp_root}" 2>/dev/null || true' EXIT

render_cnpg() {
  local output_file="$1"
  shift

  "${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
    --show-only templates/cnpg-cluster.yaml \
    --set global.imageTag="v1.0.0" \
    "$@" >"${output_file}"
}

assert_wal_cap() {
  local rendered="$1"
  local expected="$2"

  python3 - "$rendered" "$expected" <<'PY'
import re
import sys

path, expected = sys.argv[1:3]
text = open(path, "r", encoding="utf-8").read()

match = re.search(
    r'^\s*"max_slot_wal_keep_size":\s+"(?P<value>[^"]+)"\s*$',
    text,
    re.MULTILINE,
)

if match is None:
    print("missing max_slot_wal_keep_size", file=sys.stderr)
    sys.exit(1)

actual = match.group("value")

if actual != expected:
    print(
        f"max_slot_wal_keep_size: expected {expected!r}, got {actual!r}",
        file=sys.stderr,
    )
    sys.exit(1)

if actual.endswith(("Gi", "Ti")):
    print(
        "max_slot_wal_keep_size must use PostgreSQL units, not Kubernetes resource units",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

default_render="${tmpdir}/default.yaml"
minimum_render="${tmpdir}/minimum.yaml"
override_render="${tmpdir}/override.yaml"

render_cnpg "${default_render}" --set cnpg.storageSize=100Gi
assert_wal_cap "${default_render}" "30GB"

render_cnpg "${minimum_render}" --set cnpg.storageSize=20Gi
assert_wal_cap "${minimum_render}" "10GB"

render_cnpg "${override_render}" --set cnpg.maxSlotWalKeepSize=250GB
assert_wal_cap "${override_render}" "250GB"

echo "CNPG WAL cap Helm defaults are safe"
