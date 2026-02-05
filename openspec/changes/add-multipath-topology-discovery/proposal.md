# Change: Add Multipath Topology Discovery

## Why
Traditional network discovery often misses multiple paths in networks that utilize Equal-Cost Multi-Path (ECMP) or other load-balancing techniques. By integrating Diamond-Miner (D-Miner) inspired multipath topology discovery, ServiceRadar will provide a more comprehensive view of complex network topologies. This is particularly valuable for operators of carrier-grade, enterprise, and data center networks where multipath routing is common.

## What Changes
- **ADDED** `DiscoveryTypeMultipath` to the discovery engine types.
- **ADDED** A multipath probing engine in `pkg/scan` that uses randomized flow identifiers and TTLs to discover topology diamonds.
- **ADDED** Support for multipath discovery in `pkg/mapper`, allowing it to orchestrate D-Miner style probes.
- **MODIFIED** `DiscoveryJob` configuration to include parameters for multipath discovery, such as `max_ttl`, `probes_per_hop`, and `probing_rate`.
- **MODIFIED** The network topology ingestion layer to handle multipath links and project them into the Apache AGE graph.
- **ADDED** Visualization support in the web UI to represent multipath "diamonds" and load-balanced links.

## Impact
- **Affected specs**: `network-discovery`, `agent-configuration`.
- **Affected code**: `pkg/mapper`, `pkg/agent`, `pkg/scan`, `elixir/serviceradar_core`, `web-ng`.
- **Data Model**: Updates to `TopologyLink` and the Apache AGE schema to support multiple edges between nodes with flow-identifying metadata.
