## ADDED Requirements

### Requirement: NetFlow processor writes BGP observations
The system SHALL modify ServiceRadar.EventWriter.Processors.NetflowMetrics to call BGP.Ingestor when processing flows with BGP data.

#### Scenario: NetFlow with AS path creates BGP observation
- **WHEN** NetFlow processor receives flow with as_path [64512, 64513]
- **THEN** system calls BGP.Ingestor.upsert_observation before writing netflow_metrics row

#### Scenario: NetFlow without BGP data skips observation
- **WHEN** NetFlow processor receives flow without as_path or communities
- **THEN** system writes netflow_metrics row with bgp_observation_id=NULL (no BGP.Ingestor call)

### Requirement: NetFlow sets bgp_observation_id foreign key
The system SHALL add bgp_observation_id UUID column to netflow_metrics table referencing bgp_routing_info.

#### Scenario: Link flow to BGP observation
- **WHEN** NetFlow processor upserts BGP observation returning id=<uuid>
- **THEN** system sets netflow_metrics.bgp_observation_id=<uuid> before INSERT

#### Scenario: Null observation ID for non-BGP flows
- **WHEN** NetFlow flow has no BGP data
- **THEN** system writes netflow_metrics row with bgp_observation_id=NULL

#### Scenario: Foreign key constraint enforced
- **WHEN** NetFlow attempts to set bgp_observation_id to non-existent UUID
- **THEN** database rejects INSERT with foreign key violation error

### Requirement: Deprecate NetFlow BGP columns
The system SHALL mark netflow_metrics.as_path and netflow_metrics.bgp_communities columns as deprecated for future removal.

#### Scenario: Migration populates old and new columns
- **WHEN** NetFlow processor writes flow with BGP data (during migration phase)
- **THEN** system writes BOTH deprecated columns AND creates bgp_routing_info observation

#### Scenario: New deployments skip deprecated columns
- **WHEN** fresh deployment initializes database schema (post-migration)
- **THEN** system creates netflow_metrics without as_path/bgp_communities columns

### Requirement: Backfill existing NetFlow BGP data
The system SHALL provide migration to create bgp_routing_info records from existing netflow_metrics rows and populate bgp_observation_id.

#### Scenario: Backfill creates BGP observations
- **WHEN** migration runs on existing netflow_metrics with as_path data
- **THEN** system creates bgp_routing_info records grouped by (timestamp_bucket, as_path, communities) and SUMs bytes/packets

#### Scenario: Backfill sets observation IDs
- **WHEN** bgp_routing_info records created from backfill
- **THEN** system UPDATEs netflow_metrics.bgp_observation_id to reference new observations

#### Scenario: Backfill handles NULL BGP data
- **WHEN** netflow_metrics row has NULL as_path
- **THEN** migration leaves bgp_observation_id=NULL (no observation created)

### Requirement: NetFlow extraction supports IPFIX BGP fields
The system SHALL extract BGP data from IPFIX fields including bgpSourceAsNumber (16), bgpDestinationAsNumber (17), bgpSourceCommunityList (484).

#### Scenario: Extract source and destination AS
- **WHEN** IPFIX record has bgpSourceAsNumber=64512, bgpDestinationAsNumber=8075
- **THEN** system constructs as_path [64512, 8075]

#### Scenario: Extract full AS path from IPFIX
- **WHEN** IPFIX record includes bgpNextHopAsPath field (enterprise-specific)
- **THEN** system parses full AS path sequence [64512, 64513, 64514, 8075]

#### Scenario: Extract BGP communities
- **WHEN** IPFIX record has bgpSourceCommunityList=[100:200, NO_EXPORT]
- **THEN** system converts to INTEGER[] [6553800, 4294967041]

### Requirement: NetFlow v9 BGP field support
The system SHALL extract BGP data from NetFlow v9 fields including SRC_AS (16), DST_AS (17), BGP_IPV4_NEXT_HOP (18).

#### Scenario: Extract NetFlow v9 AS path
- **WHEN** NetFlow v9 record has SRC_AS=64512, DST_AS=8075
- **THEN** system creates as_path [64512, 8075]

#### Scenario: NetFlow v9 missing AS fields
- **WHEN** NetFlow v9 record does not include SRC_AS or DST_AS
- **THEN** system writes flow without BGP observation (bgp_observation_id=NULL)

### Requirement: Sampler address stored in BGP metadata
The system SHALL include NetFlow sampler address in bgp_routing_info.metadata for observation source tracking.

#### Scenario: Record sampler address
- **WHEN** NetFlow processor creates BGP observation from flow received from sampler 10.0.1.100
- **THEN** system sets metadata={source_protocol: 'netflow', sampler_address: '10.0.1.100'}

#### Scenario: Query observations by sampler
- **WHEN** user queries "BGP data from sampler 10.0.1.100"
- **THEN** system filters bgp_routing_info WHERE metadata->>'sampler_address'='10.0.1.100'
