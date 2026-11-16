# camera-recording Delta

## ADDED Requirements

### Requirement: Sealed media always has an automatic drainer
Every recorder spool that holds sealed media SHALL have an automatic drainer that starts with the recorder, rescans its spool on start, and retries until each sealed block reaches a terminal disposition: with an archive destination configured, a verified archive receipt or a verified quarantine-destination archive receipt; in local-only mode (no archive destination configured), a verified local-retention publication.

A manual command SHALL NOT be the only drain path. A dispatch whose outcome is
unknown SHALL be reconciled automatically through idempotent read-back
(no-clobber write, then existence and ranged content verification) and SHALL NOT
require operator reconciliation. Unsealed or interrupted blocks SHALL be
recovered by the recorder's own startup reconciliation. Leftover upload scratch
from a crash SHALL be reconciled by the service that owns it, and SHALL NOT halt
other uploads. With an archive destination configured, only a verified archive
receipt or a verified quarantine-destination archive receipt SHALL end the
drainer for a block, a local publication SHALL NOT stop it, and sealed media
SHALL NOT be deleted before one of those receipts. In local-only mode a
verified local-retention publication means the block is published into the
qualified durable local archive and its central index receipt is persisted;
that publication ends the drainer for the block, and local deletion then
follows the retention and hold policy, never before that publication.

#### Scenario: A sealed NVR block drains without an operator
- **GIVEN** an NVR holding a sealed block with no archive receipt
- **WHEN** the NVR starts and its archive destination is reachable
- **THEN** the block SHALL be archived and its receipt persisted without any manual command

#### Scenario: A local publication does not stop an archive-backed drainer
- **GIVEN** an NVR with an archive destination configured and a sealed block that has a local-retention publication but no archive receipt
- **WHEN** the drainer runs
- **THEN** it SHALL keep retrying until a verified archive or quarantine-destination receipt exists
- **AND** the block SHALL NOT be deleted before that receipt

#### Scenario: A local-only recorder finishes on a verified local publication
- **GIVEN** an NVR in local-only mode with no archive destination configured
- **WHEN** a sealed block is published into the qualified durable local archive and its central index receipt is persisted
- **THEN** the drainer SHALL stop for that block
- **AND** the block SHALL be deleted only as the retention and hold policy allows, never before that publication

#### Scenario: An unknown upload outcome is reconciled
- **GIVEN** a dispatch whose upload request ended without a known outcome
- **WHEN** the drainer retries it
- **THEN** it SHALL verify the existing object and record the receipt when it matches, or upload without overwriting when it is absent

### Requirement: Sealed media is judged against the authority it was sealed under
The archive path SHALL authorize a sealed block from the recovery generation, archive binding and recorder grant that were valid when the block was sealed, verified against retained history, and SHALL NOT refuse it only because the current generation or binding has changed.

A block whose seal names a generation or binding absent from retained history,
or one ended for a compromise-class reason, SHALL never be published for
playback and SHALL never be left in the recorder spool. With an archive
destination configured it SHALL be archived to a quarantine destination and
reported; its verified quarantine-destination receipt is terminal. In
local-only mode it SHALL be placed in a quarantine partition (or carry a
quarantine flag) of the same qualified durable local archive: retained,
counted and reported, never indexed for playback and never auto-deleted. That
placement, with its central index receipt persisted, is terminal for the
drainer. No separate store SHALL be introduced for it.

#### Scenario: Generation drift does not freeze draining
- **GIVEN** a block sealed under recovery generation 7
- **WHEN** core advances the recovery generation to 8
- **THEN** the block SHALL still be archived under its generation 7 seal

#### Scenario: A seal with no retained history is quarantined
- **WHEN** a block's seal names a generation that retained history does not hold
- **THEN** the block SHALL be archived to the quarantine destination and reported
- **AND** SHALL NOT be published for playback
- **AND** once its quarantine receipt is verified the drainer SHALL stop retrying it and the recorder MAY delete its local copy

#### Scenario: A local-only recorder quarantines a seal with no retained history
- **GIVEN** an NVR in local-only mode with no archive destination configured
- **WHEN** a sealed block's seal names a generation that retained history does not hold
- **THEN** the block SHALL be placed in the quarantine partition of the qualified durable local archive with its central index receipt persisted, and the drainer SHALL stop for it
- **AND** it SHALL be counted and reported, SHALL NOT be indexed for playback and SHALL NOT be auto-deleted
