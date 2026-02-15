## Why

Network engineers need BGP routing visibility in NetFlow data to analyze traffic patterns by AS path and BGP community tags. The current OCSF-normalized NetFlow pipeline discards BGP metadata needed for network analysis and troubleshooting. Additionally, the existing Go zen-consumer adds operational complexity as a separate service to maintain.

## What Changes

- Add Elixir Broadway consumer for raw NetFlow metrics in core-elx EventWriter
- Extract and store BGP routing information (AS path, BGP communities) from IPFIX flow messages
- Create `netflow_metrics` hypertable optimized for network analysis queries with GIN indexes
- Route `flows.raw.netflow` NATS subject to new NetFlowMetrics processor
- Generate Elixir protobuf code for FlowMessage to decode binary NATS messages
- Eliminate dependency on separate Go zen-consumer service (architectural simplification)

## Capabilities

### New Capabilities
- `netflow-bgp-ingestion`: Consume raw NetFlow protobuf messages from NATS JetStream and decode BGP routing data (AS paths, BGP communities)
- `netflow-bgp-storage`: Store NetFlow metrics with BGP fields in PostgreSQL with optimized indexing for AS path containment queries
- `netflow-bgp-ui`: Display BGP routing information in the NetFlow UI with AS path visualization, filtering by AS number/community, and topology graphs

### Modified Capabilities
<!-- No existing capabilities being modified - this is net new functionality -->

## Impact

**Code Changes:**
- New `NetFlowMetrics` processor in `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/netflow_metrics.ex`
- New protobuf module `elixir/serviceradar_core/lib/serviceradar/proto/flow.pb.ex`
- Updates to `elixir/serviceradar_core/lib/serviceradar/event_writer/pipeline.ex` (routing rules)
- Updates to `elixir/serviceradar_core/lib/serviceradar/event_writer/config.ex` (NETFLOW_RAW stream subscription)

**Database:**
- New `netflow_metrics` hypertable with BGP fields (as_path INTEGER[], bgp_communities INTEGER[])
- GIN indexes for array containment queries (`WHERE as_path @> ARRAY[64512]`)

**Architecture:**
- Consolidates message consumption into core-elx EventWriter (eliminates zen-consumer Go service)
- Parallel data flows: OCSF normalized (security) + raw metrics (network analysis)
- Follows existing Broadway/GenStage pattern for NATS JetStream consumption

**Data Flow:**
Rust collector → NATS (`flows.raw.netflow`) → EventWriter.Producer → NetFlowMetrics processor → PostgreSQL (`netflow_metrics` table)
