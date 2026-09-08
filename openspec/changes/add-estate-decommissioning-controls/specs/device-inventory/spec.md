# device-inventory Specification

## ADDED Requirements

### Requirement: Device Expiry By Last Seen

A device that has not been seen within a configured retention window SHALL be soft-deleted
by a scheduled expiry pass, recording the reason and the actor. Purging of soft-deleted
rows SHALL remain the responsibility of the existing cleanup worker.

Expiry SHALL be disabled by default. An estate that has never expired devices may hold a
very large stale population -- `demo` holds 49,932 rows unseen for over 30 days -- and
enabling expiry SHALL be a deliberate operator action rather than a silent consequence of
upgrading.

An expiry pass SHALL be subject to a mass-deletion guard on the same terms as the topology
canonical prune, and SHALL report when the guard blocks it.

A device that reports again after expiry SHALL be revived by the existing identity paths,
and that revival SHALL be recorded in the revival audit rather than silently clearing the
expiry reason.

#### Scenario: A departed device is expired
- **GIVEN** a device whose `last_seen_time` is older than the retention window
- **AND** device expiry is enabled with that window configured
- **WHEN** the expiry pass runs
- **THEN** the device is soft-deleted with a reason identifying expiry
- **AND** the existing cleanup worker purges it after its own retention period

#### Scenario: A still-reporting device is never expired
- **GIVEN** a device whose agent reports every heartbeat
- **WHEN** the expiry pass runs
- **THEN** the device is not soft-deleted, regardless of how long ago it was first seen

#### Scenario: A first expiry pass over a large stale population is guarded
- **GIVEN** expiry is enabled for the first time on an estate where most devices are stale
- **WHEN** the pass would soft-delete more than the guard's permitted fraction
- **THEN** the pass is refused
- **AND** the refusal is logged with the counts and the override required to proceed
