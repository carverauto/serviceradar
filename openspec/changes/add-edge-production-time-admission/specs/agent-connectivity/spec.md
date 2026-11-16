# agent-connectivity Delta

## ADDED Requirements

### Requirement: A new agent hands off older storage layouts on first start
On opening its edge record root, the agent SHALL hand off every committed record that a known older layout holds through late admission, and SHALL retire that layout only after every committed record in it has a local terminal disposition.

The agent SHALL keep a registry of known legacy layouts; the pre-lane flat
spool is `flat_v1`. For each layout present, the agent SHALL inspect it
read-only, read committed records above the resolved watermark in sequence
order, and for each record either append it to the late generation and wait
for the append to become durable before resolving it in the legacy layout, or
append it durably to the per-principal hold before resolving it when its origin
principal is not the authenticated agent, or write it to rejection evidence and
resolve it when it is permanently invalid. A rejection-evidence write that is
paused or refused SHALL be retryable, and the legacy record SHALL stay
unresolved until that write succeeds. A retryable refusal SHALL stop the pass
without skipping or reordering, and the pass SHALL be retried. A crash between the late append and the legacy resolve
SHALL NOT produce a second copy in the late generation. While committed records
remain, the agent SHALL report `legacy_storage_handoff_pending` with the record
count, bytes, oldest age and refusal reason. `unsupported_legacy_storage` SHALL
apply only to root entries the agent cannot account for. Neither condition SHALL
make live production not ready.

#### Scenario: The flat spool tail left by an upgrade is handed off
- **GIVEN** a flat spool written by an agent before the lane format that holds two committed, unresolved records produced five days ago
- **WHEN** the upgraded agent opens its edge record root
- **THEN** it SHALL append both records to the late generation in sequence order
- **AND** SHALL resolve them in the flat spool and retire the flat spool
- **AND** SHALL NOT report `unsupported_legacy_storage`

#### Scenario: A crash during handoff does not duplicate a record
- **GIVEN** a record appended to the late generation whose flat-spool resolve did not complete before a crash
- **WHEN** the agent restarts and resumes the handoff
- **THEN** the late generation SHALL hold exactly one copy of the record

#### Scenario: A paused rejection-evidence write keeps the legacy record
- **GIVEN** a local rejection quarantine at its bound and a flat spool whose next committed record is permanently invalid
- **WHEN** the handoff tries to write that record to rejection evidence and the write is refused
- **THEN** the agent SHALL NOT resolve the record in the flat spool
- **AND** SHALL stop the pass, report `legacy_storage_handoff_pending` and retry until the evidence write succeeds

#### Scenario: A retryable refusal pauses the handoff in order
- **GIVEN** a flat spool whose first unresolved record cannot be validated because the trust snapshot is not yet available
- **WHEN** the handoff runs
- **THEN** no record SHALL be resolved or appended
- **AND** the agent SHALL report `legacy_storage_handoff_pending` with the reason and retry

### Requirement: The local rejection quarantine is drained, not evicted
The agent SHALL deliver every local rejection quarantine entry centrally to the reject-audit stream on a late session and SHALL remove an entry only after its central receipt.

A full quarantine SHALL pause the acceptance of new rejections and count them;
it SHALL NOT evict an undelivered entry.

#### Scenario: A full quarantine keeps its oldest entry
- **WHEN** the quarantine is at its byte or count bound and a new permanent rejection arrives
- **THEN** the agent SHALL keep every undelivered entry and report the paused rejection

### Requirement: An add-on relay spool is not orphaned by a configuration change
When an add-on's relay spool directory or delivery backend changes, the add-on SHALL drain the unacknowledged frames of the previous spool before abandoning it, or adopt them into the new spool.

The add-on SHALL report the previous spool's remaining frames until they drain.

#### Scenario: Changing the spool directory keeps old frames
- **GIVEN** an OTel add-on with unacknowledged frames in its spool directory
- **WHEN** the configured `spool_dir` changes
- **THEN** the old frames SHALL be delivered or adopted before the old directory is abandoned
