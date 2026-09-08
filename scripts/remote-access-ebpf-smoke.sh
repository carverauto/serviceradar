#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_INTEGRATION="${SERVICERADAR_AGENT_EBPF_INTEGRATION:-0}"

if [ "${1:-}" = "--integration" ]; then
  RUN_INTEGRATION=1
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/remote-access-ebpf-smoke.sh [--integration]" >&2
  exit 2
fi

cd "${REPO_ROOT}"

go test ./go/pkg/agent/remoteaccess -run 'TestNormalizeBPF(Command|File|Network)Event|TestBPFNetworkAddressIPv6|TestBPFLossTrackerEmitsCounters|TestManagerEmitsNormalizedEnhancedRecordingEvents' -count=1
go test ./go/pkg/agent/ebpf ./go/pkg/agent/ebpf/probes -run 'Test(CapabilityReport|RuntimeCheck|LoadSelftest|LoadCommand|LoadFile|LoadNetwork|LossCounter)' -count=1

if [ "${RUN_INTEGRATION}" = "1" ]; then
  if [ "$(uname -s)" != "Linux" ]; then
    echo "eBPF integration smoke requires Linux" >&2
    exit 1
  fi

  SERVICERADAR_AGENT_EBPF_INTEGRATION=1 \
    go test ./go/pkg/agent/ebpf -run '^TestRuntimeLoadsSelftestCollectionIntegration$' -count=1 -v
fi

echo "remote-access eBPF smoke succeeded"
