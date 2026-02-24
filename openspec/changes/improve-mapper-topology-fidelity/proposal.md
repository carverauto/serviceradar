# Change: Improve mapper topology fidelity and discovery coverage

## Why
Current mapper/discovery output in the `demo` environment is not producing an accurate topology for the farm01/tonka01 network and is missing known downstream devices. Direct CNPG inspection on 2026-02-15 shows:
- `platform.mapper_topology_links` has 5,622 rows but only two emitting local devices (`192.168.1.195`, `192.168.1.131`).
- `neighbor_mgmt_addr` is empty for all rows (`0/5622`), preventing neighbor-IP/device resolution.
- `platform_graph."CONNECTS_TO"` has only 3 edges, and projected adjacency is incomplete vs expected farm01 topology.
- `platform.ocsf_devices` does not contain known devices `192.168.10.154` (Aruba switch) and `192.168.10.96` (endpoint behind Aruba).
- Mapper seeds are currently `192.168.10.1` and `192.168.2.1`; farm01 uses multiple interface IPs and discovery should normalize these to one canonical router identity.

Without stronger traversal, neighbor resolution, and projection guarantees, topology data in Apache AGE and inventory will remain low quality.

## What Changes
- Strengthen `serviceradar-agent` mapper discovery traversal so configured seeds and discovered routed subnets are explored deterministically with bounded recursion.
- Normalize topology evidence in mapper output to include stable neighbor identity signals (management IP, chassis ID, port ID, MAC/ARP fallback, protocol source, confidence).
- Require ingestion to resolve neighbor observations to canonical device IDs and persist unresolved observations for later reconciliation.
- Tighten AGE projection semantics so `CONNECTS_TO` represents device-to-device adjacency while interface-level evidence is preserved separately.
- Add endpoint promotion rules from switch/router evidence so unmanaged clients observed via ARP/bridge/CAM are represented in inventory with confidence and freshness metadata.
- Add topology quality metrics and acceptance checks that fail jobs when required neighbor identity fields are absent beyond threshold.
- Add regression fixtures covering the documented farm01/tonka01 topology and Aruba-side endpoint visibility.

## Impact
- Affected specs:
  - `network-discovery`
  - `age-graph`
  - `device-inventory`
- Affected code (expected):
  - `pkg/mapper/discovery.go`
  - `pkg/mapper/snmp_polling.go`
  - `pkg/mapper/publisher.go`
  - `pkg/mapper/types.go`
  - mapper protobuf/result payload structures
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/topology/topology_graph.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/*`
  - topology/inventory dashboards and quality telemetry surfaces
