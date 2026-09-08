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

tmp_root="${ROOT_DIR}/.helm-web-ng-extra-env-value-from-check"
mkdir -p "${tmp_root}"
tmpdir="$(mktemp -d "${tmp_root}/run.XXXXXXXX")"
trap 'rm -rf "${tmpdir}"; rmdir "${tmp_root}" 2>/dev/null || true' EXIT

render="${tmpdir}/render.yaml"

"${HELM_CMD[@]}" template serviceradar "${CHART_DIR}" \
  --set global.imageTag="v1.0.0" \
  --set-string webNg.extraEnv.SERVICERADAR_FEATURE_MODE="enabled" \
  --set-string webNg.extraEnvValueFrom.SMTP_USERNAME.secretKeyRef.name="serviceradar-smtp-relay" \
  --set-string webNg.extraEnvValueFrom.SMTP_USERNAME.secretKeyRef.key="username" \
  --set-string webNg.extraEnvValueFrom.SMTP_PASSWORD.secretKeyRef.name="smtp-password-literal-must-not-render" \
  --set-string webNg.extraEnvValueFrom.SMTP_PASSWORD.secretKeyRef.key="password" \
  --debug >"${render}"

python3 - "${render}" <<'PY'
import re
import sys

render_path = sys.argv[1]
text = open(render_path, "r", encoding="utf-8").read()
lines = text.splitlines()


def scalar(value):
    return value.strip().strip('"\'')


def named_list_blocks(names):
    blocks = {name: [] for name in names}

    for index, line in enumerate(lines):
        match = re.match(r"^(?P<indent>\s*)-\s+name:\s*(?P<name>.+?)\s*$", line)
        if not match:
            continue

        name = scalar(match.group("name"))
        if name not in blocks:
            continue

        indent = len(match.group("indent"))
        block = [line]
        for following in lines[index + 1 :]:
            stripped = following.strip()
            following_indent = len(following) - len(following.lstrip())
            if stripped and following_indent <= indent:
                break
            block.append(following)

        blocks[name].append((indent, "\n".join(block)))

    return blocks


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


expected_secret_refs = {
    "SMTP_USERNAME": ("serviceradar-smtp-relay", "username"),
    "SMTP_PASSWORD": ("smtp-password-literal-must-not-render", "password"),
}
blocks = named_list_blocks(set(expected_secret_refs) | {"SERVICERADAR_FEATURE_MODE"})

for env_name, (secret_name, secret_key) in expected_secret_refs.items():
    entries = blocks[env_name]
    if len(entries) != 1:
        fail(f"expected exactly one {env_name} environment entry, found {len(entries)}")

    _indent, block = entries[0]
    if not re.search(r"^\s+valueFrom:\s*$", block, re.MULTILINE):
        fail(f"{env_name} must render valueFrom")
    if not re.search(r"^\s+secretKeyRef:\s*$", block, re.MULTILINE):
        fail(f"{env_name} must render secretKeyRef")
    if not re.search(
        rf"^\s+name:\s*[\"']?{re.escape(secret_name)}[\"']?\s*$",
        block,
        re.MULTILINE,
    ):
        fail(f"{env_name} must reference Secret {secret_name}")
    if not re.search(
        rf"^\s+key:\s*[\"']?{re.escape(secret_key)}[\"']?\s*$",
        block,
        re.MULTILINE,
    ):
        fail(f"{env_name} must reference key {secret_key}")
    if re.search(r"^\s+value:\s*", block, re.MULTILINE):
        fail(f"{env_name} rendered a literal value alongside valueFrom")

literal_entries = blocks["SERVICERADAR_FEATURE_MODE"]
if len(literal_entries) != 1:
    fail(
        "expected exactly one SERVICERADAR_FEATURE_MODE environment entry, "
        f"found {len(literal_entries)}"
    )

_literal_indent, literal_block = literal_entries[0]
if not re.search(
    r"^\s+value:\s*[\"']?enabled[\"']?\s*$",
    literal_block,
    re.MULTILINE,
):
    fail("literal webNg.extraEnv values must continue to render")
if re.search(r"^\s+valueFrom:\s*$", literal_block, re.MULTILINE):
    fail("literal webNg.extraEnv value unexpectedly rendered valueFrom")
PY

echo "web-ng secret-backed environment values are rendered without literal credentials"
