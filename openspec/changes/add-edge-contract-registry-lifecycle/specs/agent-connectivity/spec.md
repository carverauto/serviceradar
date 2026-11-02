# agent-connectivity Delta

## ADDED Requirements

### Requirement: Output contract and format are sticky per producer run
The output contract and format SHALL remain sticky for each producer run. The
exact v1 output-contract bundle, registry epoch, encoding, route profile, and
traffic class SHALL be selected
before a producer run starts and SHALL remain immutable for that run and every
retry. A shared lane MAY multiplex records from different contracts. Changing
rollout configuration SHALL affect only new runs while pinned backlog drains.

#### Scenario: Rollback occurs with a v1 spool backlog
- **WHEN** operators roll back a cohort after v1 cutover
- **THEN** the control plane SHALL disable new affected runs while the agent
  continues opening compatible v1 record lanes until its existing spool resolves
- **AND** no rollback binary lacking that spool reader/sender or historical
  contract registry SHALL replace it
- **AND** rollback SHALL NOT select or generate new legacy JSON output

#### Scenario: Connection changes during a run
- **WHEN** an agent reconnects to another ready gateway while a v1 run is
  active
- **THEN** it SHALL reopen each lane with the same spool identity and first
  unresolved sequence
- **AND** the run SHALL remain pinned without dual authoritative emission

#### Scenario: Registry changes during an existing run
- **WHEN** a new registry epoch activates while an old run has spooled records
- **THEN** the old run SHALL drain under its pinned historical bundle and route
- **AND** only new runs SHALL use the new effective grant

