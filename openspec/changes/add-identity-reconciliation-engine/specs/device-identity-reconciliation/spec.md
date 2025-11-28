## ADDED Requirements
### Requirement: Network Sightings Lifecycle
The system SHALL persist network sightings as low-confidence, partition-scoped observations with source, timestamps, subnet, TTL expiry, and metadata (DNS/ports/fingerprint status), keeping at most one active sighting per partition+IP.

#### Scenario: Record and refresh a sighting
- **WHEN** a sweep/poller/agent reports a sighting for an IP without strong identifiers
- **THEN** an active sighting record is created or refreshed with updated last_seen and TTL without creating a UnifiedDevice

### Requirement: Identifier Indexing and Strong-ID Merge
The system SHALL index strong (MAC, serial, agent ID, cloud/external IDs) and middle (hostname, fingerprint hash) identifiers, and SHALL attach sightings or devices to the existing UnifiedDevice when a strong identifier matches, merging weaker records instead of generating a new device.

#### Scenario: Strong ID arrives after sighting
- **WHEN** a MAC or external ID is observed for an IP that already has an active sighting or Tier 2 device
- **THEN** the sighting/device is merged into the canonical device keyed by that strong identifier, and the canonical device retains history and identifiers

### Requirement: Policy-Driven Promotion
The system SHALL promote a sighting to a UnifiedDevice only when subnet policy criteria are met (e.g., persistence duration, fingerprint/hostname confidence, allow-IP-as-ID flag) and SHALL keep or block promotion when criteria fail.

#### Scenario: Dynamic subnet requires persistence + fingerprint
- **WHEN** a sighting in a dynamic subnet lacks fingerprint/hostname after the persistence window
- **THEN** it remains a sighting and is not promoted, and promotion is deferred until policy conditions are satisfied

### Requirement: Reaper and TTL Enforcement
The system SHALL enforce per-subnet TTLs for sightings and low-confidence devices, expiring them when they exceed policy limits while leaving promoted Tier 1 devices untouched.

#### Scenario: Expire stale guest sighting
- **WHEN** a guest-subnet sighting exceeds its configured TTL without promotion
- **THEN** the reaper marks it expired and removes it from active listings without affecting devices in other tiers

### Requirement: Auditability and Metrics
The system SHALL record audit events for promotion, merge, and expiry decisions and SHALL expose metrics for sightings, promotions, merges, reaper actions, and policy blocks.

#### Scenario: Promotion audit trail
- **WHEN** a sighting is promoted or merged
- **THEN** an audit event is written with decision reason, identifiers used, and acting policy, and metrics counters are incremented

### Requirement: Sightings UI/API Separation and Overrides
The system SHALL expose API/UI views that list sightings separately from device inventory and SHALL allow authorized operators to promote, dismiss, or override policy for individual sightings with audit logging.

#### Scenario: Operator promotes a sighting
- **WHEN** an operator issues a promotion action on a sighting via API/UI
- **THEN** the system creates/attaches to the appropriate device per identifiers, records the override in audit logs, and updates listings so the sighting no longer appears active

#### Scenario: Operator sees promotion context
- **WHEN** a sighting is displayed in the UI
- **THEN** the UI highlights the identifiers present (hostname/MAC/fingerprint), shows the active policy state (e.g., promotion disabled or awaiting thresholds), and explains why it remains a sighting

#### Scenario: Paginate through active sightings
- **WHEN** an operator has more active sightings than the current page size
- **THEN** the API/UI return total counts and support `limit`/`offset` pagination so the operator can page through all sightings

### Requirement: Promotion Lineage Visibility
The system SHALL surface on device detail views when and how a device was promoted (source sighting ID, time, policy/override) so operators can audit identity assignment.

#### Scenario: View promotion history on device
- **WHEN** an operator opens a device detail page
- **THEN** they can see promotion metadata including the originating sighting (if applicable), promotion timestamp, and whether it was auto, policy-driven, or manual override

### Requirement: Strong-ID Merge Under IP Churn
The system SHALL treat strong identifiers (e.g., MAC, Armis ID, NetBox ID) as canonical across IP churn, merging repeated sightings/updates that share those identifiers into a single device and keeping inventory within the expected strong-ID cardinality (e.g., 50k faker devices plus internal services).

#### Scenario: Faker IP shuffle does not inflate inventory
- **WHEN** multiple sightings arrive over time for the same `armis_device_id` or MAC but with different IPs/hostnames
- **THEN** the reconciliation engine attaches them to the existing canonical device instead of creating new devices, and total device inventory stays within the configured strong-ID baseline tolerance

### Requirement: Sweep Sightings Enrich Strong-ID Devices
The system SHALL merge sweep/poller sightings whose IP matches an existing Tier 1 UnifiedDevice anchored by strong identifiers, treating the sighting as availability/port enrichment instead of leaving it pending in the sightings store.

#### Scenario: Sweep sighting attaches to canonical device
- **WHEN** a sweep sighting arrives for an IP that maps to exactly one canonical device in the partition (keyed by strong identifiers and without conflicting identifiers)
- **THEN** the sighting is absorbed into that device, availability/port data is recorded on the device, an audit entry is written, and the sighting no longer remains active

### Requirement: Promotion Availability Defaults
The system SHALL mark devices promoted from sightings as unavailable/unknown until a successful health probe is ingested and SHALL NOT mark them available solely because a sighting was promoted.

#### Scenario: Unreachable faker devices stay unavailable
- **WHEN** a sighting with no successful sweep/agent availability is promoted to a device
- **THEN** the resulting device remains unavailable (or unknown) and only flips to available after a positive probe result is processed

### Requirement: Cardinality Drift Detection
The system SHALL surface metrics/alerts when reconciled device counts deviate beyond a configurable tolerance from the strong-identifier baseline and SHALL block or rate-limit further promotion when drift is detected until operators acknowledge/override.

#### Scenario: Device count exceeds baseline tolerance
- **WHEN** the reconciled device inventory exceeds the configured baseline (e.g., 50k faker devices) by more than the tolerance for a sustained window
- **THEN** an alert is emitted and promotion is paused or gated until the drift is addressed or explicitly overridden
