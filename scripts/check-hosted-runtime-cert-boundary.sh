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

tmp_root="${ROOT_DIR}/.helm-hosted-cert-boundary-check"
mkdir -p "${tmp_root}"
tmpdir="$(mktemp -d "${tmp_root}/run.XXXXXXXX")"
trap 'rm -rf "${tmpdir}"; rmdir "${tmp_root}" 2>/dev/null || true' EXIT

default_render="${tmpdir}/default.yaml"
hosted_render="${tmpdir}/hosted.yaml"

"${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
  --set global.imageTag="v1.0.0" \
  --debug >"${default_render}"

"${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
  --namespace tenant-acme \
  --values "${CHART_DIR}/values-tenant.yaml" \
  --set global.imageTag="v1.0.0" \
  --set partitionId="acme" \
  --set cnpg.clientCAFromCerts=true \
  --set cnpg.clientCASecret="cnpg-client-ca" \
  --set certs.generator.enabled=true \
  --set certs.regenerator.enabled=true \
  --debug >"${hosted_render}"

python3 - "${default_render}" "${hosted_render}" <<'PY'
import re
import sys

default_path, hosted_path = sys.argv[1:]
default_text = open(default_path, "r", encoding="utf-8").read()
hosted_text = open(hosted_path, "r", encoding="utf-8").read()

RUNTIME = "serviceradar-runtime-certs"
ISSUER = "serviceradar-runtime-issuer-ca"
CNPG_ISSUER = "serviceradar-cnpg-issuer-ca"
TARGETS = {RUNTIME, ISSUER, CNPG_ISSUER}
REVISION_ANNOTATION = "serviceradar.io/runtime-tls-revision"


def documents(text):
    return [doc for doc in re.split(r"^---\s*$", text, flags=re.MULTILINE) if doc.strip()]


def scalar(doc, field):
    match = re.search(rf"^{re.escape(field)}:\s*([^\n]+)", doc, re.MULTILINE)
    return match.group(1).strip(" \"'") if match else None


def metadata_name(doc):
    match = re.search(
        r"^metadata:\n(?P<body>(?:[ \t].*\n?)*)", doc, re.MULTILINE
    )
    if not match:
        return None
    name = re.search(r"^\s+name:\s*([^\n]+)", match.group("body"), re.MULTILINE)
    return name.group(1).strip(" \"'") if name else None


def resources(text):
    result = {}
    for doc in documents(text):
        kind = scalar(doc, "kind")
        name = metadata_name(doc)
        if kind and name:
            result[(kind, name)] = doc
    return result


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


default_resources = resources(default_text)
hosted_resources = resources(hosted_text)

if ("Job", "serviceradar-runtime-cert-generator") not in default_resources:
    fail("self-managed render must retain the runtime certificate generator")

for key in [
    ("Job", "serviceradar-runtime-cert-generator"),
    ("Role", "serviceradar-runtime-cert-generator"),
    ("Job", "serviceradar-runtime-cert-regenerator"),
    ("Role", "serviceradar-runtime-cert-regenerator"),
]:
    if key in hosted_resources:
        fail(f"hosted render must suppress {key[0]}/{key[1]}")

generator_role = default_resources[("Role", "serviceradar-runtime-cert-generator")]
if "resourceNames:" not in generator_role or not re.search(
    rf"^\s*-\s*[\"']?{re.escape(RUNTIME)}[\"']?\s*$", generator_role, re.MULTILINE
):
    fail("certificate generator RBAC must name the exact runtime Secret")
for forbidden_verb in ["list", "watch", "update", "delete"]:
    if re.search(rf"^\s*verbs:.*\b{forbidden_verb}\b", generator_role, re.MULTILINE):
        fail(f"certificate generator RBAC contains forbidden verb {forbidden_verb}")

if "k8s-agent-acme-chain.pem" not in hosted_text or "k8s-agent-acme-key.pem" not in hosted_text:
    fail("hosted partitionId must drive the default agent certificate projection")
if "k8s-agent-default-chain.pem" in hosted_text or "k8s-agent-default-key.pem" in hosted_text:
    fail("hosted runtime config still references the stale default partition certificate")


def projected_secret_blocks(doc):
    lines = doc.splitlines()
    blocks = []

    for index, line in enumerate(lines):
        match = re.match(r"^(?P<indent>\s*)secretName:\s*[\"']?(?P<name>[^\s\"']+)", line)
        if not match or match.group("name") not in TARGETS:
            continue

        indent = len(match.group("indent"))
        block = [line]
        for following in lines[index + 1 :]:
            stripped = following.strip()
            following_indent = len(following) - len(following.lstrip())
            if stripped and following_indent < indent:
                break
            block.append(following)

        keys = []
        projections = []
        pending_key = None
        for block_line in block:
            key = re.match(r"^\s*- key:\s*[\"']?([^\s\"']+)", block_line)
            if key:
                pending_key = key.group(1)
                keys.append(pending_key)
                continue

            path = re.match(r"^\s+path:\s*[\"']?([^\s\"']+)", block_line)
            if path and pending_key:
                projections.append((pending_key, path.group(1)))
                pending_key = None

        blocks.append((match.group("name"), keys, projections))

    return blocks


long_lived_consumers = 0
for (kind, name), doc in hosted_resources.items():
    blocks = projected_secret_blocks(doc)
    if not blocks:
        continue

    for secret_name, keys, _projections in blocks:
        if not keys:
            fail(f"{kind}/{name} projects {secret_name} without explicit items")
        if secret_name == RUNTIME and ({"root-key.pem", "cnpg-ca-key.pem"} & set(keys)):
            fail(f"{kind}/{name} projects a CA signing key from the runtime Secret")
        if secret_name == ISSUER and set(keys) != {"root.pem", "root-key.pem"}:
            fail(f"{kind}/{name} has an unexpected edge issuer projection: {keys}")
        if secret_name == CNPG_ISSUER and set(keys) != {"cnpg-ca.pem", "cnpg-ca-key.pem"}:
            fail(f"{kind}/{name} has an unexpected CNPG issuer projection: {keys}")

    if kind in {"Deployment", "StatefulSet"}:
        long_lived_consumers += 1
        if REVISION_ANNOTATION not in doc:
            fail(f"{kind}/{name} consumes runtime TLS without the rollout revision annotation")

if long_lived_consumers == 0:
    fail("hosted render did not contain any long-lived runtime TLS consumers")

if not any(
    name == ISSUER
    for doc in hosted_resources.values()
    for name, _, _ in projected_secret_blocks(doc)
):
    fail("hosted render does not project the isolated edge issuer Secret")
if not any(
    name == CNPG_ISSUER
    for doc in hosted_resources.values()
    for name, _, _ in projected_secret_blocks(doc)
):
    fail("hosted render does not project the isolated CNPG issuer Secret")

rperf = hosted_resources.get(("Deployment", "serviceradar-rperf-client"))
if not rperf:
    fail("hosted render does not contain the rperf client Deployment")

rperf_runtime_blocks = [
    (keys, projections)
    for secret_name, keys, projections in projected_secret_blocks(rperf)
    if secret_name == RUNTIME
]
if len(rperf_runtime_blocks) != 1:
    fail("rperf client must project exactly one runtime certificate Secret volume")

rperf_keys, rperf_projections = rperf_runtime_blocks[0]
expected_rperf_projections = {
    ("root.pem", "root.pem"),
    ("rperf-checker.pem", "rperf-checker.pem"),
    ("rperf-checker-key.pem", "rperf-checker-key.pem"),
    ("rperf-checker.pem", "rperf-client.pem"),
    ("rperf-checker-key.pem", "rperf-client-key.pem"),
}
if set(rperf_projections) != expected_rperf_projections:
    fail(f"rperf client has an unexpected runtime certificate projection: {rperf_projections}")
if set(rperf_keys) != {"root.pem", "rperf-checker.pem", "rperf-checker-key.pem"}:
    fail(f"rperf client projects unexpected runtime Secret keys: {rperf_keys}")
PY

echo "Hosted runtime certificate boundary is enforced"
