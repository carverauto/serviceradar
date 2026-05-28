#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

expected_kernel="${SERVICERADAR_NETPROBE_EXPECT_KERNEL:-}"
object_path="${SERVICERADAR_NETPROBE_EBPF_OBJECT:-}"

if [[ -z "${object_path}" ]]; then
  bazel build --config=ci --remote_download_outputs=all //rust/netprobe/ebpf:netprobe_ebpf_object
  object_path="$(
    bazel cquery \
      --config=ci \
      //rust/netprobe/ebpf:netprobe_ebpf_object \
      --output=files | tail -n 1
  )"
  if [[ "${object_path#/}" = "${object_path}" ]]; then
    object_path="$(bazel info execution_root)/${object_path}"
  fi
fi

if [[ ! -f "${object_path}" ]]; then
  echo "netprobe eBPF object not found: ${object_path}" >&2
  exit 1
fi

args=("${object_path}")
if [[ -n "${expected_kernel}" ]]; then
  args+=(--expect-kernel "${expected_kernel}")
fi

sfw cargo run \
  -p serviceradar-netprobe \
  --no-default-features \
  --bin netprobe-ebpf-verify \
  -- "${args[@]}"
