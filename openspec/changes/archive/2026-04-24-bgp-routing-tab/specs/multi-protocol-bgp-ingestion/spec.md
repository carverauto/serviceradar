## ADDED Requirements

### Requirement: Protocol-agnostic BGP ingestion interface
The system SHALL provide ServiceRadar.BGP.Ingestor module with protocol-agnostic interface for writing BGP observations from any source.

#### Scenario: NetFlow calls common ingestion interface
- **WHEN** NetFlow processor extracts BGP data from flow
- **THEN** system calls BGP.Ingestor.upsert_observation(source: :netflow, as_path: [...], communities: [...], ...)

#### Scenario: Future sFlow integration
- **WHEN** sFlow processor extracts BGP data
- **THEN** system calls same BGP.Ingestor.upsert_observation(source: :sflow, ...) interface

#### Scenario: Ingestion validates source protocol
- **WHEN** caller provides invalid source_protocol value
- **THEN** system returns validation error with allowed values (netflow, sflow, bgp_peering)

### Requirement: Upsert BGP observations with aggregation
The system SHALL use PostgreSQL ON CONFLICT UPDATE to deduplicate BGP observations and maintain aggregation counters.

#### Scenario: First observation for AS path
- **WHEN** BGP.Ingestor receives first observation for (timestamp_bucket, as_path, communities, endpoints)
- **THEN** system INSERTs new bgp_routing_info record with initial bytes/packets/flow_count

#### Scenario: Duplicate AS path observation
- **WHEN** BGP.Ingestor receives observation matching existing record's unique key
- **THEN** system UPDATEs existing record incrementing total_bytes, total_packets, flow_count

#### Scenario: Upsert within same timestamp bucket
- **WHEN** observations arrive with timestamps 10:00:15 and 10:00:45 for same AS path
- **THEN** system groups into same 1-minute bucket (10:00:00) and aggregates

### Requirement: Batch BGP observation writes
The system SHALL support batching multiple BGP observations in single database transaction for performance.

#### Scenario: Batch NetFlow BGP data
- **WHEN** NetFlow processor receives 100 flows with BGP data
- **THEN** system groups by (as_path, communities), upserts observations in single transaction, returns observation IDs

#### Scenario: Batch size limit
- **WHEN** batch exceeds 1000 observations
- **THEN** system splits into multiple transactions of max 1000 observations each

### Requirement: Return observation IDs for flow linking
The system SHALL return bgp_routing_info.id (UUID) after upsert to enable flow table foreign key assignment.

#### Scenario: NetFlow links to observation
- **WHEN** BGP.Ingestor.upsert_observation returns {ok, observation_id}
- **THEN** NetFlow processor sets netflow_metrics.bgp_observation_id = observation_id before writing flow

#### Scenario: Observation upsert failure
- **WHEN** BGP.Ingestor.upsert_observation fails (database error)
- **THEN** system returns {error, reason} and NetFlow processor sets bgp_observation_id to NULL

### Requirement: Extract BGP data from flow records
The system SHALL extract AS path and BGP communities from protocol-specific flow formats (NetFlow v9/IPFIX, sFlow).

#### Scenario: Extract NetFlow v9 BGP data
- **WHEN** NetFlow v9 record includes fields BGP_IPV4_NEXT_HOP (field 18), SRC_AS (16), DST_AS (17)
- **THEN** system constructs as_path from SRC_AS → DST_AS

#### Scenario: Extract IPFIX BGP communities
- **WHEN** IPFIX record includes bgpSourceCommunityList (field 484)
- **THEN** system parses community list into INTEGER[] array

#### Scenario: Extract sFlow BGP data
- **WHEN** sFlow extended_gateway structure includes as_path and communities
- **THEN** system extracts as_path sequence and community values

#### Scenario: Missing BGP data in flow
- **WHEN** flow record does not include AS or community fields
- **THEN** system skips BGP observation creation, writes flow without bgp_observation_id

### Requirement: PubSub broadcast on observation create
The system SHALL broadcast to Phoenix PubSub "bgp:observations" topic when creating or updating bgp_routing_info records.

#### Scenario: New observation triggers broadcast
- **WHEN** BGP.Ingestor creates new bgp_routing_info record
- **THEN** system broadcasts %{action: :created, observation_id: id} to "bgp:observations" topic

#### Scenario: Observation update triggers broadcast
- **WHEN** BGP.Ingestor updates existing observation (aggregation)
- **THEN** system broadcasts %{action: :updated, observation_id: id, added_bytes: X}

#### Scenario: LiveView receives broadcast
- **WHEN** broadcast sent to "bgp:observations"
- **THEN** subscribed BGPLive.Index processes receive message and refresh data

### Requirement: Source protocol metadata storage
The system SHALL store source_protocol and optional metadata JSONB column for protocol-specific context.

#### Scenario: NetFlow stores sampler address
- **WHEN** NetFlow observation created
- **THEN** system stores source_protocol='netflow', metadata={sampler_address: "10.0.1.1"}

#### Scenario: BGP peering stores peer AS
- **WHEN** future BGP peering observation created
- **THEN** system stores source_protocol='bgp_peering', metadata={peer_as: 64512, peer_ip: "10.0.2.1"}

### Requirement: AS path validation
The system SHALL validate AS path arrays contain valid AS numbers (1-4294967295, non-empty).

#### Scenario: Valid AS path accepted
- **WHEN** BGP.Ingestor receives as_path [64512, 64513, 8075]
- **THEN** system validates all AS numbers in valid range and creates observation

#### Scenario: Invalid AS number rejected
- **WHEN** BGP.Ingestor receives as_path [0, 64512] (AS 0 reserved)
- **THEN** system returns validation error "Invalid AS number: 0"

#### Scenario: Empty AS path rejected
- **WHEN** BGP.Ingestor receives empty as_path []
- **THEN** system returns validation error "AS path cannot be empty"
