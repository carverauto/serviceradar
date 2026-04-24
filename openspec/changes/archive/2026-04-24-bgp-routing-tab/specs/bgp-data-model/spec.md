## ADDED Requirements

### Requirement: BGP observation storage
The system SHALL store BGP routing observations in a protocol-agnostic table that supports multiple data sources (NetFlow, sFlow, BGP peering).

#### Scenario: Store NetFlow BGP observation
- **WHEN** NetFlow processor receives a flow with AS path [64512, 64513, 8075]
- **THEN** system creates or updates bgp_routing_info record with source_protocol='netflow', as_path=[64512, 64513, 8075]

#### Scenario: Store sFlow BGP observation
- **WHEN** sFlow processor receives a sample with AS path [64512, 15169]
- **THEN** system creates or updates bgp_routing_info record with source_protocol='sflow', as_path=[64512, 15169]

#### Scenario: Deduplicate identical AS paths
- **WHEN** multiple flows share the same (timestamp bucket, as_path, communities, src_ip, dst_ip)
- **THEN** system creates single bgp_routing_info record and increments aggregation counters (total_bytes, flow_count)

### Requirement: AS path array storage
The system SHALL store AS paths as PostgreSQL INTEGER[] arrays to enable efficient path analysis queries.

#### Scenario: Query flows through specific AS
- **WHEN** user queries "flows through AS 64513"
- **THEN** system uses GIN index to find bgp_routing_info WHERE as_path @> ARRAY[64513]

#### Scenario: Query AS path length
- **WHEN** user queries "AS paths with 5 or more hops"
- **THEN** system filters WHERE array_length(as_path, 1) >= 5

### Requirement: BGP community storage
The system SHALL store BGP communities as PostgreSQL INTEGER[] arrays with 32-bit encoded values (AS:value format).

#### Scenario: Store standard BGP communities
- **WHEN** flow has communities [100:200, 200:300]
- **THEN** system stores as INTEGER[] [6553800, 13107500] (upper 16 bits = AS, lower 16 bits = value)

#### Scenario: Store well-known communities
- **WHEN** flow has NO_EXPORT community
- **THEN** system stores as INTEGER[] [4294967041] (0xFFFFFF01)

#### Scenario: Query by community
- **WHEN** user queries "flows with community 100:200"
- **THEN** system uses GIN index to find bgp_routing_info WHERE bgp_communities @> ARRAY[6553800]

### Requirement: Flow reference to BGP observation
The system SHALL link flow records (netflow_metrics, sflow_metrics) to BGP observations via foreign key relationship.

#### Scenario: NetFlow record references BGP observation
- **WHEN** NetFlow processor writes flow with BGP data
- **THEN** system sets netflow_metrics.bgp_observation_id to reference bgp_routing_info.id

#### Scenario: Flow without BGP data
- **WHEN** NetFlow processor writes flow without AS path
- **THEN** system sets netflow_metrics.bgp_observation_id to NULL

### Requirement: TimescaleDB hypertable partitioning
The system SHALL partition bgp_routing_info as a TimescaleDB hypertable on timestamp column for efficient time-series queries.

#### Scenario: Query recent BGP observations
- **WHEN** user queries BGP data for last 24 hours
- **THEN** system queries only relevant time partitions (chunks) for performance

#### Scenario: Retention policy enforcement
- **WHEN** bgp_routing_info chunks older than retention period exist
- **THEN** system automatically drops old chunks per TimescaleDB retention policy

### Requirement: Ash resource for BGP observations
The system SHALL provide ServiceRadar.BGP.BGPObservation Ash resource with authorization policies using SystemActor for background processes.

#### Scenario: SystemActor reads BGP observations
- **WHEN** BGPStats module queries observations with actor: SystemActor.system(:bgp_stats)
- **THEN** system authorizes read and returns observations from current platform schema

#### Scenario: Unauthorized user query blocked
- **WHEN** unauthenticated request attempts to read bgp_routing_info
- **THEN** system returns authorization error

### Requirement: BGP aggregation columns
The system SHALL maintain aggregation columns (total_bytes, total_packets, flow_count) on bgp_routing_info for query performance.

#### Scenario: Update aggregations on flow insert
- **WHEN** flow with 1000 bytes references BGP observation
- **THEN** system increments bgp_routing_info.total_bytes by 1000 and flow_count by 1

#### Scenario: Query traffic by AS without flow JOIN
- **WHEN** user queries "total bytes through AS 64513"
- **THEN** system SUMs bgp_routing_info.total_bytes WHERE as_path @> ARRAY[64513] (no JOIN required)
