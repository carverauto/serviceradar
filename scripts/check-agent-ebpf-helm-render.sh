#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/helm/serviceradar"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  if ! rg -q -- "${pattern}" "${file}"; then
    echo "expected ${file} to contain pattern: ${pattern}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -q -- "${pattern}" "${file}"; then
    echo "expected ${file} to omit pattern: ${pattern}" >&2
    exit 1
  fi
}

require_cmd helm
require_cmd rg

default_render="${TMP_DIR}/default.yaml"
netraw_render="${TMP_DIR}/netraw.yaml"
ebpf_render="${TMP_DIR}/ebpf.yaml"

helm template serviceradar "${CHART}" >"${default_render}"
helm template serviceradar "${CHART}" \
  --set agent.allowNetRaw=true \
  --set agent.ebpf.enabled=false \
  >"${netraw_render}"
helm template serviceradar "${CHART}" \
  --set agent.allowNetRaw=false \
  --set agent.ebpf.enabled=true \
  >"${ebpf_render}"

assert_contains "${default_render}" 'name: SERVICERADAR_AGENT_EBPF_ENABLED'
assert_contains "${default_render}" 'value: "false"'
assert_not_contains "${default_render}" 'name: bpffs'
assert_not_contains "${default_render}" '- "BPF"'
assert_not_contains "${default_render}" '- "PERFMON"'
assert_not_contains "${default_render}" '- "SYS_RESOURCE"'

assert_contains "${netraw_render}" 'NET_RAW'
assert_not_contains "${netraw_render}" 'name: bpffs'
assert_not_contains "${netraw_render}" '- "BPF"'
assert_not_contains "${netraw_render}" '- "PERFMON"'
assert_not_contains "${netraw_render}" '- "SYS_RESOURCE"'

assert_contains "${ebpf_render}" 'name: bpffs'
assert_contains "${ebpf_render}" 'name: kernel-btf'
assert_contains "${ebpf_render}" 'name: cgroup-fs'
assert_contains "${ebpf_render}" '- "BPF"'
assert_contains "${ebpf_render}" '- "PERFMON"'
assert_contains "${ebpf_render}" '- "SYS_RESOURCE"'
assert_contains "${ebpf_render}" 'name: SERVICERADAR_AGENT_EBPF_ENABLED'
assert_contains "${ebpf_render}" 'value: "true"'
assert_not_contains "${ebpf_render}" 'NET_RAW'

echo "agent eBPF Helm render checks succeeded"
