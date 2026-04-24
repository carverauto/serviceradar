## ADDED Requirements

### Requirement: NetFlow raw subject uses one canonical contract
The system SHALL use a single explicit, versioned payload contract for `flows.raw.netflow`. All in-repo publishers and consumers on that subject SHALL encode and decode the same contract without relying on implicit format assumptions.

#### Scenario: Collector payload is decoded successfully
- **GIVEN** the NetFlow collector publishes a record to `flows.raw.netflow`
- **WHEN** the NetFlow ingestion pipeline consumes that message
- **THEN** the message SHALL decode successfully without format guessing
- **AND** the pipeline SHALL record the contract version it accepted

#### Scenario: Canonical contract uses protobuf bytes
- **GIVEN** the NetFlow collector publishes to `flows.raw.netflow`
- **WHEN** the message is emitted onto NATS
- **THEN** the payload SHALL be encoded as protobuf `FlowMessage` bytes
- **AND** the payload SHALL NOT require JSON translation before downstream decoding

#### Scenario: Contract mismatch is surfaced immediately
- **GIVEN** a NetFlow consumer receives a payload that does not match the canonical contract
- **WHEN** decode fails
- **THEN** the system SHALL emit a structured decode failure signal
- **AND** operators SHALL be able to identify the failing stage without relying on an empty UI symptom alone

### Requirement: NetFlow uses one canonical persisted flow model
The system SHALL persist each successfully decoded NetFlow/IPFIX record into `platform.ocsf_network_activity` as the only canonical per-flow storage model used by the UI, SRQL, enrichment, and rollups.

#### Scenario: NetFlow record becomes visible in the UI flow path
- **GIVEN** a valid NetFlow/IPFIX export reaches the collector
- **WHEN** the record is processed successfully
- **THEN** a corresponding row SHALL be written to `platform.ocsf_network_activity`
- **AND** the record SHALL be queryable through `in:flows`

#### Scenario: NetFlow UI visibility does not depend on netflow_metrics
- **GIVEN** a valid NetFlow/IPFIX export reaches the collector
- **WHEN** the record is processed successfully
- **THEN** UI-visible NetFlow data SHALL come from `platform.ocsf_network_activity`
- **AND** the codebase SHALL NOT retain `platform.netflow_metrics` as an active per-flow storage path

### Requirement: BGP analytics derive from canonical NetFlow decode
The system SHALL derive BGP analytics from the same decoded NetFlow/IPFIX protobuf message without introducing a second per-flow source of truth.

#### Scenario: BGP-capable NetFlow record updates derived BGP analytics
- **GIVEN** a valid NetFlow/IPFIX export includes AS path or BGP community data
- **WHEN** the record is processed successfully
- **THEN** a corresponding derived observation SHALL be written or aggregated into `platform.bgp_routing_info`
- **AND** BGP analytics SHALL remain queryable without depending on `platform.netflow_metrics`

### Requirement: NetFlow ingestion exposes stage-level health
The system SHALL expose stage-level NetFlow ingestion health covering receive, publish, decode, canonical persistence, and derived analytics persistence.

#### Scenario: Decode failure blocks UI visibility
- **GIVEN** the collector is receiving NetFlow datagrams
- **AND** `flows.raw.netflow` messages are being published
- **WHEN** decode fails in downstream processing
- **THEN** the system SHALL expose non-zero receive/publish counts
- **AND** it SHALL expose decode failures with the last known reason

#### Scenario: OCSF persistence fails while BGP derivation may continue
- **GIVEN** NetFlow messages decode successfully
- **WHEN** writes to `platform.ocsf_network_activity` fail
- **THEN** the system SHALL report the canonical flow-path failure explicitly
- **AND** operators SHALL be able to distinguish UI-path failure from any derived BGP analytics updates

### Requirement: NetFlow golden path does not require external transform promotion
The canonical NetFlow UI path SHALL NOT require an external transform or rule bootstrap step to reach `platform.ocsf_network_activity`.

#### Scenario: Missing transform asset does not block canonical UI flow ingestion
- **GIVEN** a deployment does not install a NetFlow transform or promotion asset
- **WHEN** valid NetFlow/IPFIX exports reach the collector
- **THEN** the canonical OCSF flow path SHALL still persist rows to `platform.ocsf_network_activity`
- **AND** `/flows`, `/netflow`, and `in:flows` SHALL remain functional
