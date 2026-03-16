## Why

ServiceRadar's IPFIX v10 collector currently ignores BGP-specific information elements in flow records. Extracting and visualizing BGP fields (AS numbers, AS paths, communities, next-hop AS) provides routing visibility and helps correlate traffic flows with BGP routing decisions.

## What Changes

- Extend IPFIX v10 parser to extract BGP information elements from flow records
- Add BGP fields to flow data model and protobuf definitions
- Update ingestion pipeline to process and store BGP flow metadata
- Add UI components to display BGP routing information from flows

## Capabilities

### New Capabilities
- `bgp-flow-fields`: Parse and ingest BGP information elements from IPFIX v10 (AS numbers, AS paths, BGP communities, next-hop AS)
- `bgp-flow-ui`: UI components for visualizing BGP routing information from flow data

### Modified Capabilities
<!-- No existing capabilities require requirement changes -->

## Impact

**IPFIX Collector** (existing):
- Parser updates to extract BGP information elements (IEs 16, 17, 128+)
- Protobuf schema additions for BGP flow fields

**Elixir Backend**:
- Ingestion handler updates for BGP flow attributes
- Database schema for BGP metadata storage

**Web UI**:
- New views/components for BGP flow visualization
- AS path displays, routing metrics, and BGP-aware flow analysis
