## ADDED Requirements

### Requirement: Complete device match sets
The system MUST read every device matching a filter when the caller needs the full match set, by streaming or by following `more?` until exhaustion. The caller MUST NOT treat one page of `Device.read` as the full set. A device that was not returned because the read stopped early MUST NOT be treated as absent.

This applies to SNMP profile target compilation, mapper promotion, sweep restoration of soft-deleted devices, interface classification context, netflow exporter and interface cache device hydration, and god-view hydration of topology node ids.

#### Scenario: SNMP profile scope larger than one page
- **WHEN** an SNMP profile scope matches more devices than `Device.read`'s default page
- **THEN** the compiler SHALL emit a target for every matching device

#### Scenario: Mapper promotion sees every candidate device
- **WHEN** a sweep promotion batch names more device uids than one default page
- **THEN** each of those devices SHALL be loaded before promotion decides whether the candidate exists

#### Scenario: Soft-deleted devices past the first page are still restored
- **WHEN** sweep ingestion asks to restore more tombstoned uids than one default page
- **THEN** every eligible uid SHALL be restored

### Requirement: Hostile-flow exposure covers its window
Device IOC exposure derived from attributed flows MUST evaluate the configured time window. A newest-N row limit MAY size one batch. It MUST NOT end the evaluation while matching flows remain in the window.

#### Scenario: Window larger than one flow batch
- **WHEN** the exposure window contains more matching flows than one batch
- **THEN** exposure SHALL account for the matching flows beyond that batch

## MODIFIED Requirements

### Requirement: OCSF Device Export

The system SHALL provide an API endpoint to export device inventory in OCSF-compliant JSON format. One response SHALL be a single page. The page MUST report a continuation when further matching devices exist, and walking that continuation to exhaustion SHALL yield every device that matches the request filters.

#### Scenario: Export all devices
- **GIVEN** a user with appropriate permissions
- **WHEN** they request `GET /api/devices/ocsf/export` and follow `next_offset` until it is absent
- **THEN** the combined pages SHALL contain every device as an OCSF Device object
- **AND** each object SHALL conform to OCSF v1.7.0 Device schema
- **AND** a page shorter than the requested limit SHALL still report a continuation when more devices match

#### Scenario: Export filtered by type
- **GIVEN** a user requesting only router devices
- **WHEN** they request `GET /api/devices/ocsf/export?type_id=12`
- **THEN** the response SHALL contain only devices with `type_id = 12`

#### Scenario: Export with time range
- **GIVEN** a user requesting devices seen in the last 24 hours
- **WHEN** they request `GET /api/devices/ocsf/export?last_seen_after=<timestamp>`
- **THEN** the response SHALL contain only devices with `last_seen_time` >= the specified timestamp
