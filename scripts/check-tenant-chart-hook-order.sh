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

tmp_root="${ROOT_DIR}/.helm-tenant-hook-order-check"
mkdir -p "${tmp_root}"
tmpdir="$(mktemp -d "${tmp_root}/run.XXXXXXXX")"
trap 'rm -rf "${tmpdir}"; rmdir "${tmp_root}" 2>/dev/null || true' EXIT

rendered="${tmpdir}/rendered.yaml"

"${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
  --set global.imageTag="v1.0.0" \
  --debug >"${rendered}"

python3 - "${rendered}" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()

targets = {
    ("Job", "serviceradar-secret-generator"): -5,
    ("Job", "serviceradar-nats-creds-generator"): -4,
    ("Job", "serviceradar-core-migrations"): -1,
}


def unquote(value):
    value = value.strip()
    if "#" in value:
        value = value.split("#", 1)[0].strip()
    return value.strip("\"'")


def metadata_body(doc):
    match = re.search(r"^metadata:\n(?P<body>(?:[ \t].*\n?)*)", doc, re.MULTILINE)
    return match.group("body") if match else ""


def hook_weight(doc):
    body = metadata_body(doc)
    hook = re.search(r'^\s+["\']?helm\.sh/hook["\']?\s*:', body, re.MULTILINE)
    weight = re.search(
        r'^\s+["\']?helm\.sh/hook-weight["\']?\s*:\s*(?P<weight>[^\n]+)',
        body,
        re.MULTILINE,
    )

    if hook is None:
        return None
    if weight is None:
        raise ValueError("missing helm.sh/hook-weight")

    return int(unquote(weight.group("weight")))


def restart_policy(doc):
    match = re.search(
        r"^\s+restartPolicy:\s*(?P<policy>[^\n]+)",
        doc,
        re.MULTILINE,
    )

    return unquote(match.group("policy")) if match else ""


found = {}

for doc in re.split(r"^---\s*$", text, flags=re.MULTILINE):
    kind_match = re.search(r"^kind:\s*(?P<kind>\S+)", doc, re.MULTILINE)
    if kind_match is None:
        continue

    body = metadata_body(doc)
    name_match = re.search(r"^\s+name:\s*(?P<name>[^\n]+)", body, re.MULTILINE)
    if name_match is None:
        continue

    key = (kind_match.group("kind"), unquote(name_match.group("name")))
    if key not in targets:
        continue

    try:
        found[key] = {
            "hook_weight": hook_weight(doc),
            "restart_policy": restart_policy(doc),
        }
    except ValueError as error:
        print(f"{key[0]}/{key[1]}: {error}", file=sys.stderr)
        sys.exit(1)

missing = sorted(set(targets) - set(found))
if missing:
    for kind, name in missing:
        print(f"missing rendered hook: {kind}/{name}", file=sys.stderr)
    sys.exit(1)

for key, expected in targets.items():
    actual = found[key]["hook_weight"]
    if actual != expected:
        print(f"{key[0]}/{key[1]} hook weight: expected {expected}, got {actual}", file=sys.stderr)
        sys.exit(1)
    if found[key]["restart_policy"] != "Never":
        print(
            f"{key[0]}/{key[1]} restartPolicy: expected Never, got {found[key]['restart_policy']}",
            file=sys.stderr,
        )
        sys.exit(1)

secret_weight = found[("Job", "serviceradar-secret-generator")]["hook_weight"]
nats_weight = found[("Job", "serviceradar-nats-creds-generator")]["hook_weight"]
migration_weight = found[("Job", "serviceradar-core-migrations")]["hook_weight"]

if secret_weight >= migration_weight:
    print("serviceradar-secret-generator must run before core migrations", file=sys.stderr)
    sys.exit(1)

if nats_weight >= migration_weight:
    print("serviceradar-nats-creds-generator must run before core migrations", file=sys.stderr)
    sys.exit(1)
PY

echo "Tenant chart secret hooks run before core migrations"
