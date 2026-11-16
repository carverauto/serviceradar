# camera-recording Delta

## ADDED Requirements

### Requirement: Sealed media always has an automatic drainer
Every recorder spool that holds sealed media SHALL have an automatic drainer that starts with the recorder, rescans its spool on start, and retries until each sealed block holds a verified archive receipt or a verified local-retention publication.

A manual command SHALL NOT be the only drain path. A dispatch whose outcome is
unknown SHALL be reconciled automatically through idempotent read-back
(no-clobber write, then existence and ranged content verification) and SHALL NOT
require operator reconciliation. Unsealed or interrupted blocks SHALL be
recovered by the recorder's own startup reconciliation. Leftover upload scratch
from a crash SHALL be reconciled by the service that owns it, and SHALL NOT halt
other uploads. Sealed media SHALL NOT be deleted before its archive receipt.

#### Scenario: A sealed NVR block drains without an operator
- **GIVEN** an NVR holding a sealed block with no archive receipt
- **WHEN** the NVR starts and its archive destination is reachable
- **THEN** the block SHALL be archived and its receipt persisted without any manual command

#### Scenario: An unknown upload outcome is reconciled
- **GIVEN** a dispatch whose upload request ended without a known outcome
- **WHEN** the drainer retries it
- **THEN** it SHALL verify the existing object and record the receipt when it matches, or upload without overwriting when it is absent

### Requirement: Sealed media is judged against the authority it was sealed under
The archive path SHALL authorize a sealed block from the recovery generation, archive binding and recorder grant that were valid when the block was sealed, verified against retained history, and SHALL NOT refuse it only because the current generation or binding has changed.

A block whose seal names a generation or binding absent from retained history,
or one ended for a compromise-class reason, SHALL be archived to a quarantine
destination and reported, never published for playback and never left on the
recorder.

#### Scenario: Generation drift does not freeze draining
- **GIVEN** a block sealed under recovery generation 7
- **WHEN** core advances the recovery generation to 8
- **THEN** the block SHALL still be archived under its generation 7 seal

#### Scenario: A seal with no retained history is quarantined
- **WHEN** a block's seal names a generation that retained history does not hold
- **THEN** the block SHALL be archived to the quarantine destination and reported
- **AND** SHALL NOT be published for playback
