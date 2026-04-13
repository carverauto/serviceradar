## ADDED Requirements
### Requirement: UniFi wireless client topology extraction
The system SHALL extract wireless client association topology from configured UniFi controllers and publish those associations as endpoint attachments to the serving access point.

#### Scenario: UniFi AP reports associated wireless clients
- **GIVEN** a UniFi controller site with an access point and associated wireless clients
- **WHEN** mapper topology discovery runs in API or hybrid mode
- **THEN** the mapper SHALL publish topology links from the serving AP to each associated wireless client
- **AND** those links SHALL use endpoint-attachment semantics rather than backbone topology semantics

### Requirement: UniFi wireless client topology metadata
Controller-derived wireless client links SHALL carry metadata that distinguishes them from controller uplinks and from inferred SNMP-L2 attachment evidence.

#### Scenario: Mapper publishes controller-derived wireless client attachment
- **GIVEN** a wireless client association discovered from the UniFi controller
- **WHEN** the mapper publishes the topology link
- **THEN** the link SHALL set `metadata.source` to a UniFi wireless-client source value
- **AND** the link SHALL set `metadata.relation_type` to `ATTACHED_TO`
- **AND** the link SHALL set `metadata.evidence_class` to `endpoint-attachment`

### Requirement: UniFi wireless client identity stability
The system SHALL preserve stable client identity for controller-derived wireless client topology across repeated polls, even when only partial client metadata is available.

#### Scenario: Controller exposes MAC but not IP
- **GIVEN** a UniFi wireless client record with MAC address but no management IP
- **WHEN** the mapper publishes topology
- **THEN** the client identity SHALL still be emitted using the strongest available stable identifier
- **AND** repeated polls SHALL not create duplicate client identities solely because the IP is absent

### Requirement: UniFi wireless client topology coexists with infrastructure topology
Controller-derived wireless client topology MUST coexist with LLDP/CDP/SNMP-L2 and UniFi uplink topology without converting wireless clients into backbone peers.

#### Scenario: Same AP has uplink and wireless client associations
- **GIVEN** a UniFi access point with both upstream uplink metadata and associated wireless clients
- **WHEN** mapper discovery publishes topology
- **THEN** the AP uplink SHALL remain a backbone/infrastructure link
- **AND** wireless clients SHALL be emitted as endpoint attachments to that AP
- **AND** downstream topology projection SHALL be able to distinguish the two link classes
