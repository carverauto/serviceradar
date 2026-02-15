## Why

BGP routing information (AS paths, communities, topology) is currently coupled to NetFlow-specific code and schema. However, BGP data is orthogonal to the collection method - it can come from NetFlow v9/IPFIX, sFlow, direct BGP peering, or other routing protocols. By creating a protocol-agnostic BGP data model and dedicated UI, we enable multiple collection methods to populate routing information and provide a unified view of network topology across all data sources.

## What Changes

- **New `bgp_routing_info` database table**: Protocol-agnostic table for storing BGP AS paths, communities, and topology data with references back to source flows
- **New "BGP Routing" top-level tab**: Dedicated observability tab showing BGP topology, AS path analysis, and community statistics from all sources
- **Refactor BGP code**: Extract BGP-specific logic from `NetflowBGPStats` and `NetflowLive.Visualize` into common modules usable by any protocol
- **Multi-protocol ingestion**: NetFlow collector writes to common BGP table; future sFlow/BGP collectors can reuse the same infrastructure
- **NetFlow tab simplification**: NetFlow observability tab focuses on flow analysis, delegates BGP visualization to dedicated BGP tab

## Capabilities

### New Capabilities

- `bgp-data-model`: Common database schema and Ash resources for protocol-agnostic BGP routing data (AS paths, communities, topology observations)
- `bgp-observability-ui`: Dedicated BGP Routing tab in observability UI with AS topology graphs, path diversity metrics, traffic by AS, and community analysis
- `multi-protocol-bgp-ingestion`: Ingestion pipeline supporting multiple protocols (NetFlow, sFlow, BGP peering) writing to common BGP data model

### Modified Capabilities

- `netflow-ingestion`: NetFlow processor modified to write BGP data to common `bgp_routing_info` table instead of protocol-specific columns

## Impact

**Database Schema**:
- New table: `platform.bgp_routing_info` (timestamp, source_protocol, as_path[], bgp_communities[], src_ip, dst_ip, bytes, packets, metadata)
- Modified: `platform.netflow_metrics` (deprecate `as_path`, `bgp_communities` columns, add `bgp_observation_id` FK)
- Migration required for existing NetFlow BGP data

**Backend (Elixir)**:
- New: `ServiceRadar.BGP` domain with `BGPObservation` resource and `BGPStats` query module
- Modified: `ServiceRadar.EventWriter.Processors.NetflowMetrics` to write BGP observations
- Refactored: `NetflowBGPStats` → `ServiceRadar.BGP.Stats` (protocol-agnostic)

**UI (Phoenix LiveView)**:
- New: `ServiceRadarWebNGWeb.BGPLive.Index` (dedicated BGP routing tab)
- New: `ServiceRadarWebNGWeb.BGPLive.Components` (AS topology graph, path analysis widgets)
- Modified: `NetflowLive.Visualize` (remove BGP sections, link to BGP tab)
- Modified: `LogLive.Index` (add "BGP Routing" tab in observability navigation)

**Ingestion Pipeline**:
- Modified: NetFlow processor to populate common BGP table
- Future: sFlow, BGP peering collectors can use same BGP ingestion interface
