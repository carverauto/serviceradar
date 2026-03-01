## ADDED Requirements

### Requirement: Detected Alias Fallback Lookup
The system SHALL check `detected` IP aliases as a fallback when no confirmed alias or strong identifier matches an incoming device update, and SHALL use the detected alias to resolve to an existing device rather than creating a duplicate.

#### Scenario: Sweep result matches detected interface IP alias
- **GIVEN** a device `sr:<uuid>` has a detected IP alias `216.17.46.98` from interface discovery with `sighting_count < confirm_threshold`
- **WHEN** a sweep result arrives for IP `216.17.46.98` with no strong identifiers
- **THEN** DIRE SHALL resolve the update to the existing device via the detected alias
- **AND** SHALL NOT create a new device record for the sweep IP

#### Scenario: Multiple detected aliases for same IP
- **GIVEN** two devices have detected aliases for the same IP address (due to prior race condition)
- **WHEN** a new update arrives for that IP
- **THEN** DIRE SHALL select the device with the earliest `first_seen_at` alias timestamp
- **AND** SHALL trigger a merge operation for the conflicting devices

### Requirement: Sweep-Triggered Alias Confirmation
The system SHALL promote a `detected` IP alias to `confirmed` state when a sweep result matches that alias, treating the sweep result as strong evidence of IP association.

#### Scenario: Detected alias promoted on sweep match
- **GIVEN** a device has a detected IP alias with `sighting_count = 2` (below threshold of 3)
- **WHEN** a sweep result for that IP is resolved to the device via detected alias fallback
- **THEN** the alias state SHALL be updated to `confirmed`
- **AND** the `last_seen_at` timestamp SHALL be updated
- **AND** metadata SHALL record the sweep execution that triggered confirmation

### Requirement: Sweep Device Alias Registration
The system SHALL create an IP alias record when a new sweep-discovered device is created, ensuring the IP can be used for future identity correlation.

#### Scenario: New sweep device gets alias registered
- **GIVEN** a sweep result for IP `192.168.1.100` with no matching device or alias
- **WHEN** DIRE creates a new device `sweep-192.168.1.100-<hash>`
- **THEN** an IP alias record SHALL be created with `state: detected` and `sighting_count: 1`
- **AND** subsequent interface discoveries reporting that IP SHALL increment the alias sighting count

## MODIFIED Requirements

### Requirement: IP Alias Resolution
The system SHALL resolve IP-only device updates using IP aliases before generating a new device ID, checking confirmed aliases first and detected aliases as a fallback.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `216.17.46.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `216.17.46.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: Detected alias used as fallback
- **GIVEN** a device `sr:<uuid>` has a detected (not confirmed) IP alias `216.17.46.98`
- **AND** no confirmed alias exists for that IP
- **WHEN** a sweep result arrives for IP `216.17.46.98`
- **THEN** DIRE SHALL resolve to the device via the detected alias
- **AND** SHALL promote the alias to confirmed state

#### Scenario: Strong-ID update conflicts with confirmed IP alias
- **GIVEN** a device update with a strong identifier resolves to device ID X
- **AND** the update IP is a confirmed alias for device ID Y (Y != X)
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL merge the alias device into the strong-ID canonical device

### Requirement: Scheduled Reconciliation Backfill
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers OR detected IP aliases, and logs summary statistics for each run.

#### Scenario: Scheduled reconciliation merges duplicates via strong identifiers
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

#### Scenario: Scheduled reconciliation merges duplicates via detected IP aliases
- **GIVEN** two device IDs that have detected IP aliases for the same IP address
- **WHEN** the reconciliation job runs
- **THEN** the devices SHALL be merged, keeping the device with the earlier creation timestamp as canonical
- **AND** the surviving alias SHALL be promoted to confirmed state
