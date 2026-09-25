## ADDED Requirements

### Requirement: Ephemeral Device Expiry
The system SHALL soft-delete a live device that holds no strong identifier and has not been
seen for the configured expiry window, with a deleted reason that identifies the expiry, as
part of the scheduled device cleanup. A strong identifier is an agent, a source-authoritative
identifier, a hardware serial, or a globally-unique (not locally-administered) MAC, whether
recorded as an identifier, an own-interface MAC, the device's MAC attribute or its metadata.
The system SHALL NOT expire a device that holds a strong identifier, however long it is
unseen, nor a device an operator created, nor a device matched by the configured exclusion
query. Expiry SHALL be disabled until an operator enables it. A pass that would expire more
than the configured fraction of live devices SHALL be refused and reported unless the
operator override is set. If the exclusion query cannot be evaluated, the pass SHALL expire
nothing.

#### Scenario: A randomized-MAC device ages out
- **GIVEN** expiry is enabled with a 30-day window
- **AND** a device identified only by a locally-administered MAC was last seen 31 days ago
- **WHEN** the cleanup runs
- **THEN** the device is soft-deleted with deleted reason `stale_ephemeral`

#### Scenario: A device with a strong identifier never expires
- **GIVEN** expiry is enabled
- **AND** a device holding an Armis device id or a globally-unique MAC has not been seen for
  years
- **WHEN** the cleanup runs
- **THEN** the device is not soft-deleted

#### Scenario: An operator-excluded device never expires
- **GIVEN** an exclusion query that matches a device with no strong identifier
- **WHEN** the cleanup runs after that device's expiry window
- **THEN** the device is not soft-deleted

#### Scenario: A mass expiry is refused
- **GIVEN** a pass would expire more than the configured fraction of live devices
- **AND** the override is not set
- **WHEN** the cleanup runs
- **THEN** no device is expired
- **AND** the refusal is logged with the counts and the override that would allow it

#### Scenario: An expired device that returns is restored and audited
- **GIVEN** a device expired as `stale_ephemeral`
- **WHEN** discovery restores it
- **THEN** its identity revision is incremented
- **AND** a device revival audit row records the `stale_ephemeral` tombstone it cleared
