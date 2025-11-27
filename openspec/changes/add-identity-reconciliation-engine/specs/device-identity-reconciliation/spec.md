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

### Requirement: Promotion Lineage Visibility
The system SHALL surface on device detail views when and how a device was promoted (source sighting ID, time, policy/override) so operators can audit identity assignment.

#### Scenario: View promotion history on device
- **WHEN** an operator opens a device detail page
- **THEN** they can see promotion metadata including the originating sighting (if applicable), promotion timestamp, and whether it was auto, policy-driven, or manual override

## MODIFIED Requirements
### Requirement: Sightings UI/API Separation and Overrides
The system SHALL expose API/UI views that list sightings separately from device inventory, SHALL show why each sighting remains unpromoted (policy state, identifiers present), SHALL support paginated navigation with totals, and SHALL allow authorized operators to promote, dismiss, or override policy for individual sightings with audit logging.

#### Scenario: Operator sees promotion context
- **WHEN** a sighting is displayed in the UI
- **THEN** the UI highlights the identifiers present (hostname/MAC/fingerprint), shows the active policy state (e.g., promotion disabled or awaiting thresholds), and explains why it remains a sighting

#### Scenario: Paginate through active sightings
- **WHEN** an operator has more active sightings than the current page size
- **THEN** the API/UI return total counts and support `limit`/`offset` pagination so the operator can page through all sightings
