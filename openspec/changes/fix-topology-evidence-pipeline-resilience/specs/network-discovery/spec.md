# network-discovery — deltas

> Scope note: this change deliberately does NOT modify
> `### Requirement: Mapper topology ingestion and graph projection` —
> `improve-mapper-topology-fidelity` and `add-multipath-topology-discovery`
> both carry in-flight MODIFIED deltas for that heading. The requirements below
> are orthogonal, standalone concerns (failure isolation, freshness monitoring,
> identity promotion) that compose with those changes. The
> "Fallback identity when management IP is unavailable" scenario in
> `improve-mapper-topology-fidelity` states unresolved evidence SHALL be
> persisted rather than dropped; this change specifies the enforcement
> mechanics that make that true under validation and partial-failure
> conditions.

## ADDED Requirements

### Requirement: Topology evidence ingestion failure isolation
The system SHALL isolate per-record failures during mapper topology evidence ingestion: validation rejection of individual records MUST NOT prevent persistence or AGE graph projection of the remaining records in the same payload, and records that legitimately lack optional neighbor fields MUST NOT be rejected.

#### Scenario: Sparse-field evidence records persist
- **GIVEN** a topology link record that legitimately lacks a neighbor port identifier (e.g. SNMP-L2 ARP+FDB attachment, UniFi wireless client association, wireguard-derived link)
- **WHEN** the record is ingested
- **THEN** the record SHALL be persisted with empty-string sentinels for absent logical-key fields
- **AND** type-level casting SHALL preserve the empty-string sentinel (it MUST NOT be re-cast to null and rejected)

#### Scenario: Partial bulk failure does not abort the pipeline
- **GIVEN** a mapper topology payload in which some records fail validation and others succeed
- **WHEN** bulk persistence completes with partial success
- **THEN** the successfully persisted records SHALL continue to AGE graph projection
- **AND** each rejected record SHALL be counted in telemetry with its rejection reason and protocol
- **AND** rejected records SHALL be logged at error level with sampling

#### Scenario: Regression coverage uses real producer payload shapes
- **GIVEN** the ingestion test suite
- **WHEN** validation or schema constraints on topology evidence change
- **THEN** tests SHALL exercise payload shapes actually emitted by the mapper (FDB attachment without port id, UniFi wireless client, UniFi uplink, wireguard-derived) end-to-end through persistence and graph projection

### Requirement: Topology evidence ingest freshness monitoring
The system SHALL track the last-accepted topology evidence timestamp per protocol and per agent, and SHALL raise an actionable health signal when agents continue to deliver mapper topology payloads but no records are accepted within a configurable window.

#### Scenario: Ingest freeze detected while agents still push
- **GIVEN** an agent delivers `mapper_topology` payloads on its normal cadence
- **AND** no records for a protocol have been accepted for longer than the freshness window
- **WHEN** ingest freshness is evaluated
- **THEN** the system SHALL emit a topology-ingest health alert identifying the agent and protocol
- **AND** the alert SHALL be visible in core-side observability without requiring host log access

### Requirement: Endpoint attachment identity promotion
The system SHALL resolve switch-to-host attachment evidence (ARP/FDB port mappings, wireless client associations) to canonical `sr:` device identities by minting provisional, confidence-tiered devices for unresolved endpoint neighbors, instead of suppressing them or projecting raw MAC/IP pseudo-identifiers. Promotion feeds the attachment plane; presentation-tier bounding of endpoint fanout (per `refactor-topology-read-model-for-carrier-scale`) is unaffected.

#### Scenario: FDB-attached host gains a provisional identity
- **GIVEN** SNMP-L2 evidence maps a host MAC to a switch port
- **AND** no existing device matches the host MAC or IP
- **WHEN** topology sightings are promoted
- **THEN** a provisional `sr:` device SHALL be minted keyed by normalized MAC within the partition
- **AND** the attachment edge SHALL reference the provisional `sr:` identity on both endpoints

#### Scenario: Provisional identities are merge-inert
- **GIVEN** a provisional topology-sighted device and a corroborated device
- **WHEN** identity reconciliation evaluates merges
- **THEN** the provisional device MAY be merged into the corroborated device only when identity-proof requirements are met (topology evidence alone SHALL NOT drive the merge, per "Topology Evidence Must Not Drive Identity Equivalence")
- **AND** the provisional device SHALL NOT absorb identifiers from corroborated devices
- **AND** devices with distinct MAC addresses SHALL NOT be merged

#### Scenario: Unresolvable neighbors are dropped with accounting
- **GIVEN** a topology link whose neighbor cannot be resolved or provisionally minted
- **WHEN** the link is projected to AGE
- **THEN** the link SHALL be dropped before graph projection
- **AND** a drop counter with reason SHALL be emitted to telemetry
- **AND** no vertex with a non-`sr:` device identifier SHALL be written to the AGE graph
