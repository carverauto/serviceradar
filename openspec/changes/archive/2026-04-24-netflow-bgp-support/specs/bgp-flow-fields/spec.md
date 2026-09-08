## ADDED Requirements

### Requirement: Extract BGP AS Path from IPFIX
The collector SHALL extract AS path information from IPFIX v10 flow records when present and store it as a sequence of AS numbers.

#### Scenario: IPFIX record contains AS path
- **WHEN** an IPFIX v10 flow record contains an AS path information element
- **THEN** the collector SHALL extract the AS path and populate the `as_path` field as an ordered list of AS numbers

#### Scenario: IPFIX record lacks AS path
- **WHEN** an IPFIX v10 flow record does not contain an AS path information element
- **THEN** the collector SHALL leave the `as_path` field empty (default protobuf value)

#### Scenario: AS path exceeds maximum length
- **WHEN** an AS path contains more than 50 AS numbers
- **THEN** the collector SHALL truncate to the first 50 AS numbers and log a warning

### Requirement: Extract BGP Communities from IPFIX
The collector SHALL extract BGP community attributes from IPFIX v10 flow records when present and store them as 32-bit values.

#### Scenario: IPFIX record contains BGP communities
- **WHEN** an IPFIX v10 flow record contains BGP community information elements
- **THEN** the collector SHALL extract each community value and populate the `bgp_communities` field

#### Scenario: Multiple communities present
- **WHEN** an IPFIX record contains multiple BGP community values
- **THEN** the collector SHALL extract all communities and preserve their order in the `bgp_communities` field

#### Scenario: No BGP communities present
- **WHEN** an IPFIX v10 flow record does not contain BGP community information elements
- **THEN** the collector SHALL leave the `bgp_communities` field empty

### Requirement: Support vendor-specific IPFIX information elements
The collector SHALL support extraction of BGP fields from both IANA standard and vendor-specific enterprise IPFIX information elements.

#### Scenario: Cisco enterprise IPFIX fields
- **WHEN** an IPFIX record uses Cisco enterprise-specific information elements for BGP data
- **THEN** the collector SHALL correctly map and extract BGP communities and AS path

#### Scenario: Juniper enterprise IPFIX fields
- **WHEN** an IPFIX record uses Juniper enterprise-specific information elements for BGP data
- **THEN** the collector SHALL correctly map and extract BGP communities and AS path

#### Scenario: Unknown vendor IPFIX fields
- **WHEN** an IPFIX record uses unrecognized enterprise-specific information elements
- **THEN** the collector SHALL log the enterprise ID and field ID for future mapping

### Requirement: Preserve existing flow data
The collector SHALL maintain backward compatibility and continue to extract all existing flow fields when processing IPFIX records with or without BGP information elements.

#### Scenario: IPFIX record with BGP fields
- **WHEN** an IPFIX v10 flow record contains both standard flow fields and BGP information elements
- **THEN** the collector SHALL extract both standard fields (IPs, ports, bytes, etc.) and BGP fields

#### Scenario: IPFIX record without BGP fields
- **WHEN** an IPFIX v10 flow record contains only standard flow fields without BGP information
- **THEN** the collector SHALL extract standard fields normally and leave BGP fields empty

### Requirement: Store BGP flow data
The ingestion pipeline SHALL persist BGP flow metadata (AS path and communities) to the database for querying and visualization.

#### Scenario: Flow with BGP data ingested
- **WHEN** a flow message with populated `as_path` and `bgp_communities` fields is received
- **THEN** the backend SHALL store the BGP metadata alongside the flow record

#### Scenario: Query flows by AS number
- **WHEN** a user queries for flows traversing a specific AS number
- **THEN** the system SHALL return flows where the AS number appears in the `as_path` field

#### Scenario: Query flows by BGP community
- **WHEN** a user queries for flows with a specific BGP community value
- **THEN** the system SHALL return flows containing that community in the `bgp_communities` field
