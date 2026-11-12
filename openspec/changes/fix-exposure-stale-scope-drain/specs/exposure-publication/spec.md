## MODIFIED Requirements

### Requirement: Stale Scopes Complete Without Republishing

The system SHALL complete a claimed exposure snapshot scope without
publishing a generation when a complete generation covering the scope
finished after the scope was last requested, and SHALL sweep legacy
queue rows at publisher startup with the execution-time adoption rule.

A scope is fulfilled when a generation in state `complete` exists whose
control scope is NULL or equals the scope ordinal and whose completion time
is strictly newer than the scope row's `not_before`. The publisher checks
fulfillment after claiming a row and before publishing: fulfilled rows
complete immediately with no generation, no pipeline waves, and no warehouse
scan. Unfulfilled rows publish exactly as today. Nil (global) scopes always
publish. Generations in any other state (including `aborted`) never fulfill.
The generation-less completion requires the row to still hold the
`publishing` claim; a row re-pended concurrently stays pending.

At orphan adoption the publisher additionally terminates legacy-format
`ExposureSnapshotWorker` queue rows (states available, scheduled, or
retryable): an integer `device_ord` adopts the scope row if absent, a missing
`device_ord` adopts the fleet-wide scope row if absent, and the queue row
completes; a row naming an invalid scope is cancelled outright. Adoption
never modifies an existing scope row.

#### Scenario: Stale scope completes with no generation

- **GIVEN** a pending scope row requested at T for device ordinal 2777
- **AND** a complete generation for scope 2777 finished after T
- **WHEN** the publisher claims the scope
- **THEN** the scope completes with no new generation row
- **AND** no pipeline envelopes are retained for it.

#### Scenario: Fresh scope still publishes

- **GIVEN** a pending scope row requested at T for device ordinal 2896
- **AND** no complete generation for scope 2896 finished after T
- **WHEN** the publisher claims the scope
- **THEN** the scope publishes a fenced generation exactly as today.

#### Scenario: Aborted generation does not fulfill

- **GIVEN** a pending scope row requested at T
- **AND** the only generation covering the scope after T is `aborted`
- **WHEN** the publisher claims the scope
- **THEN** the scope publishes a fenced generation exactly as today.

#### Scenario: Global generation fulfills a device scope

- **GIVEN** a pending scope row requested at T for device ordinal 1827
- **AND** a complete generation with NULL scope finished after T
- **WHEN** the publisher claims the scope
- **THEN** the scope completes with no new generation row.

#### Scenario: Startup sweep terminates legacy rows

- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` queue row naming a
  device ordinal with no scope row
- **WHEN** the publisher runs orphan adoption
- **THEN** the scope row is adopted pending
- **AND** the queue row completes without publishing or snoozing.

#### Scenario: Startup sweep adopts fleet-wide legacy rows

- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` queue row with no
  `device_ord`
- **WHEN** the publisher runs orphan adoption
- **THEN** the fleet-wide scope row is adopted pending
- **AND** the queue row completes without publishing or snoozing.

#### Scenario: Startup sweep cancels invalid legacy rows

- **GIVEN** a scheduled legacy `ExposureSnapshotWorker` queue row naming an
  invalid scope
- **WHEN** the publisher runs orphan adoption
- **THEN** no scope row is created or modified
- **AND** the queue row is cancelled.
