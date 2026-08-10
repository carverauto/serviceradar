## ADDED Requirements

### Requirement: The add-on rollout list shows one row per logical update

The automatic rollouts list SHALL present one row per `(add-on, candidate
version)` rather than one row per rollout record. Where a single logical update
is carried by several rollout records -- a profile rollout plus per-assignment
rollouts, or several assignment rollouts covering different targets -- the row
SHALL aggregate them and report combined progress. Per-scope records SHALL
remain inspectable by expanding the row.

#### Scenario: Duplicate per-scope records collapse into one row

- **GIVEN** three assignment rollouts of `powerdns` from `0.1.3` to `0.1.4` exist
- **WHEN** an operator views the automatic rollouts list
- **THEN** exactly one `powerdns 0.1.3 -> 0.1.4` row is shown
- **AND** the row reports progress aggregated across all three records
- **AND** expanding the row lists the individual records with their scopes

#### Scenario: Distinct candidate versions remain distinct rows

- **GIVEN** a rollout of `anomaly` to `0.3.1` and a rollout of `anomaly` to `0.3.2`
- **WHEN** an operator views the automatic rollouts list
- **THEN** the two versions are shown as separate rows

### Requirement: The add-on rollout list separates outstanding work from history

The automatic rollouts list SHALL default to rollouts that are outstanding --
those an operator can still affect. Terminal rollouts, including completed,
canceled, and superseded, SHALL NOT appear in that default view, and SHALL
remain reachable through an explicit history view.

A row SHALL only offer an action that can change its state. Terminal rollouts
SHALL NOT offer resume, roll back, or cancel.

#### Scenario: Superseded rollouts leave the active list

- **GIVEN** a `bumblebee 0.1.1 -> 0.1.2` rollout has resolved as superseded
- **WHEN** an operator views the automatic rollouts list
- **THEN** that rollout is not listed as outstanding
- **AND** it is visible in the history view marked superseded
- **AND** it offers no resume, roll back, or cancel action

#### Scenario: Genuinely blocked rollouts remain prominent

- **GIVEN** one rollout is paused on a candidate fault
- **AND** several other rollouts are completed or superseded
- **WHEN** an operator views the automatic rollouts list
- **THEN** the paused rollout is shown
- **AND** the completed and superseded rollouts are not shown in that view

### Requirement: A blocked add-on rollout row names the agent and the reason

Every non-healthy rollout row SHALL show the add-on-reported reason string, the
agent it came from, and the age of that evidence. A row SHALL NOT present a bare
category such as `candidate reported unhealthy` as its only explanation.

Where a fault was classified as an environment fault and therefore did not block
the rollout, the row SHALL show the reason and indicate that it is advisory, so
that a non-blocking fault is never silently dropped.

#### Scenario: Paused row explains itself

- **GIVEN** a rollout paused because `bumblebee` reported `systemd unit failed` on `agent-sr-test-pve04`
- **WHEN** an operator views the row
- **THEN** the row shows the reason `systemd unit failed`
- **AND** it identifies `agent-sr-test-pve04`
- **AND** it shows how old that evidence is

#### Scenario: Advisory fault is visible without implying a block

- **GIVEN** `powerdns` reports a missing upstream producer on three agents
- **AND** the rollout was not paused for that reason
- **WHEN** an operator views the row
- **THEN** the reported reason is shown
- **AND** it is presented as advisory rather than as the cause of a pause

### Requirement: Add-on rows distinguish an unknown version from a reported one

Where an add-on cannot report a usable version, the fleet view SHALL show it as
unknown rather than rendering a placeholder version. A placeholder SHALL NOT be
compared against approved versions to derive update state.

#### Scenario: Add-on reporting no usable version

- **GIVEN** `otel-collector` reports version `0.0.0` and `0.1.3` is approved
- **WHEN** an operator views the add-on row
- **THEN** the running version is shown as unknown
- **AND** the row does not claim the add-on is behind by a specific number of versions
- **AND** the row indicates that version reporting is unavailable for that add-on
