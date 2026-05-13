#!/usr/bin/env bash
# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

check=0
if [[ "${1:-}" == "--check" ]]; then
  check=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: scripts/generate-agent-ebpf.sh [--check]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_dir="${repo_root}/go/pkg/agent/ebpf/probes"
probe_src_dir="${probe_dir}/src"
bpf2go_version="${BPF2GO_VERSION:-v0.21.0}"

bazel build @llvm_toolchain//:all-files-aarch64-darwin @llvm_toolchain//:all-files-x86_64-none >/dev/null
output_base="$(bazel info output_base 2>/dev/null | tail -n 1)"
llvm_root="${output_base}/external/toolchains_llvm++llvm+llvm_toolchain_llvm"
clang="${BPF2GO_CC:-${llvm_root}/bin/clang}"
strip="${BPF2GO_STRIP:-${llvm_root}/bin/llvm-strip}"

if [[ ! -x "${clang}" ]]; then
  echo "missing clang at ${clang}" >&2
  exit 1
fi
if [[ ! -x "${strip}" ]]; then
  echo "missing llvm-strip at ${strip}" >&2
  exit 1
fi

generate() {
  local out_dir="$1"
  GOPACKAGE=probes \
    BPF2GO_CC="${clang}" \
    BPF2GO_STRIP="${strip}" \
    go run "github.com/cilium/ebpf/cmd/bpf2go@${bpf2go_version}" \
      -go-package probes \
      -output-dir "${out_dir}" \
      -target bpfel,bpfeb \
      -no-global-types \
      -cflags '-O2 -g -Wall -Werror' \
      selftest "${probe_src_dir}/selftest.bpf.c"
  GOPACKAGE=probes \
    BPF2GO_CC="${clang}" \
    BPF2GO_STRIP="${strip}" \
    go run "github.com/cilium/ebpf/cmd/bpf2go@${bpf2go_version}" \
      -go-package probes \
      -output-dir "${out_dir}" \
      -target bpfel,bpfeb \
      -no-global-types \
      -cflags '-O2 -g -Wall -Werror' \
      command "${probe_src_dir}/command.bpf.c"
  GOPACKAGE=probes \
    BPF2GO_CC="${clang}" \
    BPF2GO_STRIP="${strip}" \
    go run "github.com/cilium/ebpf/cmd/bpf2go@${bpf2go_version}" \
      -go-package probes \
      -output-dir "${out_dir}" \
      -target bpfel,bpfeb \
      -no-global-types \
      -cflags '-O2 -g -Wall -Werror' \
      file "${probe_src_dir}/file.bpf.c"
  GOPACKAGE=probes \
    BPF2GO_CC="${clang}" \
    BPF2GO_STRIP="${strip}" \
    go run "github.com/cilium/ebpf/cmd/bpf2go@${bpf2go_version}" \
      -go-package probes \
      -output-dir "${out_dir}" \
      -target bpfel,bpfeb \
      -no-global-types \
      -cflags '-O2 -g -Wall -Werror' \
      network "${probe_src_dir}/network.bpf.c"
  gofmt -w "${out_dir}"/selftest_bpf*.go
  gofmt -w "${out_dir}"/command_bpf*.go
  gofmt -w "${out_dir}"/file_bpf*.go
  gofmt -w "${out_dir}"/network_bpf*.go
}

if [[ "${check}" -eq 1 ]]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  generate "${tmp_dir}"
  diff -u "${probe_dir}/selftest_bpfel.go" "${tmp_dir}/selftest_bpfel.go"
  diff -u "${probe_dir}/selftest_bpfeb.go" "${tmp_dir}/selftest_bpfeb.go"
  diff -u "${probe_dir}/command_bpfel.go" "${tmp_dir}/command_bpfel.go"
  diff -u "${probe_dir}/command_bpfeb.go" "${tmp_dir}/command_bpfeb.go"
  diff -u "${probe_dir}/file_bpfel.go" "${tmp_dir}/file_bpfel.go"
  diff -u "${probe_dir}/file_bpfeb.go" "${tmp_dir}/file_bpfeb.go"
  diff -u "${probe_dir}/network_bpfel.go" "${tmp_dir}/network_bpfel.go"
  diff -u "${probe_dir}/network_bpfeb.go" "${tmp_dir}/network_bpfeb.go"
  cmp "${probe_dir}/selftest_bpfel.o" "${tmp_dir}/selftest_bpfel.o"
  cmp "${probe_dir}/selftest_bpfeb.o" "${tmp_dir}/selftest_bpfeb.o"
  cmp "${probe_dir}/command_bpfel.o" "${tmp_dir}/command_bpfel.o"
  cmp "${probe_dir}/command_bpfeb.o" "${tmp_dir}/command_bpfeb.o"
  cmp "${probe_dir}/file_bpfel.o" "${tmp_dir}/file_bpfel.o"
  cmp "${probe_dir}/file_bpfeb.o" "${tmp_dir}/file_bpfeb.o"
  cmp "${probe_dir}/network_bpfel.o" "${tmp_dir}/network_bpfel.o"
  cmp "${probe_dir}/network_bpfeb.o" "${tmp_dir}/network_bpfeb.o"
else
  generate "${probe_dir}"
fi
