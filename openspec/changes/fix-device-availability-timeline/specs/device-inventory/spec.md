## ADDED Requirements

### Requirement: Merged availability transitions are recorded as append-only history
Core SHALL record every change of a device's merged availability state as an append-only history record, published through JetStream from the resolver's transition outbox and stored by EventWriter in StarRocks when StarRocks is enabled and in CNPG otherwise, never both.
Each record SHALL carry the device uid, the state the device left and the time that state began (null when the device had no prior decision), the state it entered and the decision time, the deciding evidence (authority class, source kind, reporter agent, rule) and the conflict flag.
Recording SHALL NOT depend on the opt-in availability event setting or a sweep group's `emit_availability_events`, and SHALL include changes written by the upgrade reconciliation. Each record SHALL carry a deterministic message id so a retried publish is stored once. No history record SHALL be written to a database except by EventWriter.

#### Scenario: A state change is recorded
- **GIVEN** a device that has been `available` since time T0
- **WHEN** the resolver decides it is `unavailable` at time T1
- **THEN** one history record is stored with from state `available`, from-since T0, to state `unavailable` and changed-at T1

#### Scenario: History does not depend on alert-event settings
- **GIVEN** availability transition events are disabled for the deployment
- **WHEN** a device's merged state changes
- **THEN** a history record is still stored
- **AND** no `device.available` or `device.unavailable` event is emitted

#### Scenario: A display-only change records nothing
- **WHEN** only the conflict flag, agent counters or provenance of a device's decision change
- **THEN** no history record is written
