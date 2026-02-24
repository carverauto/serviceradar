#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[topology-harness] mapper contract tests"
(
  cd "$ROOT_DIR"
  go test ./go/pkg/mapper/... -run 'SNMPL2|Topology|Identity|LLDP'
)

echo "[topology-harness] core projection contract tests"
(
  cd "$ROOT_DIR/elixir/serviceradar_core"
  mix test \
    test/serviceradar/network_discovery/topology_projection_contract_test.exs \
    test/serviceradar/network_discovery/mapper_results_ingestor_test.exs
)

echo "[topology-harness] PASS"
