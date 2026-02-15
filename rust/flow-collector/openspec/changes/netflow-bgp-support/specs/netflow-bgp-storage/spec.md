## ADDED Requirements

### Requirement: Store flows in netflow_metrics hypertable
The NetFlowMetrics processor MUST insert batches of flow records into the `netflow_metrics` TimescaleDB hypertable for long-term storage and analysis.

#### Scenario: Successful batch insert
- **WHEN** Processor receives a batch of 50 decoded FlowMessage records
- **THEN** All records are inserted into `netflow_metrics` table via `Repo.insert_all/3`
- **THEN** Processor returns `{:ok, 50}` indicating successful insert count
- **THEN** NATS messages are ACK'd

#### Scenario: Partial batch (below batch_size)
- **WHEN** Batch timeout (500ms) triggers with only 10 records in batch
- **THEN** All 10 records are inserted
- **THEN** Processor returns `{:ok, 10}`

#### Scenario: Empty batch
- **WHEN** All messages in batch fail to decode
- **THEN** Processor returns `{:ok, 0}` with no database operation
- **THEN** NATS messages are NACK'd for retry

#### Scenario: Database insert failure
- **WHEN** `Repo.insert_all/3` raises a database error
- **THEN** Processor catches exception and returns `{:error, reason}`
- **THEN** Broadway marks all messages as failed
- **THEN** NATS messages are NACK'd for retry

### Requirement: Store BGP AS path as INTEGER array
The processor MUST store AS path in the `as_path` column as a PostgreSQL INTEGER[] array for efficient querying.

#### Scenario: Two-hop AS path
- **WHEN** FlowMessage has `as_path` = [64512, 64515]
- **THEN** Database row contains `as_path` = `{64512, 64515}` (PostgreSQL array syntax)

#### Scenario: Multi-hop AS path
- **WHEN** FlowMessage has `as_path` = [64512, 64513, 64514, 15169]
- **THEN** Database row contains full AS path with all hops preserved

#### Scenario: No AS path
- **WHEN** FlowMessage has `as_path` = nil or []
- **THEN** Database row contains `as_path` = NULL

### Requirement: Store BGP communities as INTEGER array
The processor MUST store BGP community tags in the `bgp_communities` column as a PostgreSQL INTEGER[] array.

#### Scenario: Single community
- **WHEN** FlowMessage has `bgp_communities` = [4259840100]
- **THEN** Database row contains `bgp_communities` = `{4259840100}`

#### Scenario: Multiple communities
- **WHEN** FlowMessage has `bgp_communities` = [4259840100, 4259840200]
- **THEN** Database row contains full community list

#### Scenario: No communities
- **WHEN** FlowMessage has `bgp_communities` = nil or []
- **THEN** Database row contains `bgp_communities` = NULL

### Requirement: Store IP addresses as INET type
The processor MUST store source and destination IP addresses using PostgreSQL INET type for network operations support.

#### Scenario: Store IPv4 addresses
- **WHEN** Flow has `src_ip` = 10.1.0.100 and `dst_ip` = 198.51.100.50
- **THEN** Database stores addresses as INET type
- **THEN** Addresses can be queried with CIDR notation (e.g., `src_ip << '10.0.0.0/8'`)

#### Scenario: Store IPv6 addresses
- **WHEN** Flow has IPv6 source and destination addresses
- **THEN** Database stores full 128-bit addresses as INET type

#### Scenario: Store sampler address
- **WHEN** FlowMessage has `sampler_address` field
- **THEN** Database stores in `sampler_address` column as INET type

### Requirement: Store traffic statistics
The processor MUST store byte and packet counts for traffic volume analysis.

#### Scenario: Store flow statistics
- **WHEN** FlowMessage has `bytes` = 1500000 and `packets` = 1000
- **THEN** Database row contains `bytes_total` = 1500000 and `packets_total` = 1000

#### Scenario: Zero traffic (flow without data)
- **WHEN** FlowMessage has `bytes` = 0 and `packets` = 0
- **THEN** Database row contains NULL for both fields (normalized via `normalize_u64/1`)

### Requirement: Store protocol and port information
The processor MUST store network layer 4 protocol and port numbers for traffic classification.

#### Scenario: TCP flow
- **WHEN** FlowMessage has `proto` = 6, `src_port` = 49876, `dst_port` = 443
- **THEN** Database row contains `protocol` = 6, `src_port` = 49876, `dst_port` = 443

#### Scenario: UDP flow
- **WHEN** FlowMessage has `proto` = 17, `src_port` = 54321, `dst_port` = 53
- **THEN** Database row contains `protocol` = 17, `src_port` = 54321, `dst_port` = 53

#### Scenario: ICMP flow (no ports)
- **WHEN** FlowMessage has `proto` = 1, `src_port` = 0, `dst_port` = 0
- **THEN** Database row contains `protocol` = 1, `src_port` = NULL, `dst_port` = NULL

### Requirement: Use on_conflict strategy
The processor MUST use `on_conflict: :nothing` to silently ignore duplicate flow records.

#### Scenario: Duplicate flow rejected
- **WHEN** Same flow is inserted twice (duplicate timestamp + flow key)
- **THEN** Second insert is silently ignored
- **THEN** Insert returns count = 0 for duplicate
- **THEN** No error is raised

### Requirement: Partition flows by deployment
The processor MUST set the `partition` column to isolate flows by deployment for multi-tenant support.

#### Scenario: Default partition
- **WHEN** Flow is processed in single-deployment mode
- **THEN** Database row contains `partition` = "default"

### Requirement: Support GIN index queries on AS path
The storage layer MUST enable efficient containment queries on AS path arrays using GIN indexes.

#### Scenario: Query flows traversing specific AS
- **WHEN** User queries `WHERE as_path @> ARRAY[64512]`
- **THEN** Database uses GIN index for fast lookup
- **THEN** Returns all flows where AS 64512 appears anywhere in path

#### Scenario: Query flows between AS pair
- **WHEN** User queries `WHERE as_path @> ARRAY[64512, 64515]`
- **THEN** Database returns flows where path contains both AS numbers

### Requirement: Support GIN index queries on BGP communities
The storage layer MUST enable efficient containment queries on BGP community arrays using GIN indexes.

#### Scenario: Query flows with specific community
- **WHEN** User queries `WHERE bgp_communities @> ARRAY[4259840100]`
- **THEN** Database uses GIN index for fast lookup
- **THEN** Returns all flows tagged with that community

### Requirement: Store extended metadata in JSONB
The processor MUST store unmapped FlowMessage fields in the `metadata` JSONB column for extensibility.

#### Scenario: Store interface metadata
- **WHEN** FlowMessage has `in_if` = 10, `out_if` = 20, `vlan_id` = 100
- **THEN** Database row contains `metadata` = `{"in_if": 10, "out_if": 20, "vlan_id": 100}`

#### Scenario: Query metadata fields
- **WHEN** User queries `WHERE metadata->>'vlan_id' = '100'`
- **THEN** Database returns flows with matching VLAN ID
