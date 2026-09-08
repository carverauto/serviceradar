## ADDED Requirements

### Requirement: Configurable MTR Hypertable Retention
The CNPG database SHALL retain MTR trace and hop hypertable data according to a ServiceRadar-managed deployment setting rather than only the hard-coded migration default.

#### Scenario: Fresh install seeds MTR retention
- **GIVEN** a fresh ServiceRadar install with a configured MTR retention default
- **WHEN** Elixir migrations and bootstrap run
- **THEN** `platform.mtr_traces` and `platform.mtr_hops` have TimescaleDB retention policies matching the configured default
- **AND** the persisted ServiceRadar MTR settings row records the same retention value

#### Scenario: Upgrade preserves existing default behavior
- **GIVEN** an existing ServiceRadar install without a persisted MTR retention setting
- **WHEN** the upgrade that introduces configurable MTR retention runs
- **THEN** the persisted setting is seeded to preserve the previously installed retention behavior
- **AND** existing MTR hypertable data remains queryable until it expires under the configured policy

#### Scenario: Authorized user changes MTR retention
- **GIVEN** an authorized operator changes MTR retention in ServiceRadar settings
- **WHEN** the settings update succeeds
- **THEN** ServiceRadar removes any existing TimescaleDB retention policy for `platform.mtr_traces` and `platform.mtr_hops`
- **AND** it adds replacement retention policies using the newly configured interval
- **AND** it records whether policy reconciliation succeeded or failed

#### Scenario: Lowering retention warns about data expiry
- **GIVEN** the current MTR retention setting is longer than the submitted value
- **WHEN** an authorized operator attempts to save the shorter retention period
- **THEN** the UI warns that older MTR traces and hops may expire sooner
- **AND** the policy is not changed until the operator confirms the update

#### Scenario: db-event-writer never manages MTR retention
- **WHEN** MTR retention is installed, reconciled, or changed
- **THEN** schema and TimescaleDB policy management are performed by Elixir migrations or ServiceRadar Elixir control-plane code
- **AND** the db-event-writer service does not create, remove, or alter MTR tables or TimescaleDB retention policies

### Requirement: MTR Retention Policy Status
The system SHALL expose the effective MTR retention policy status from CNPG so operators can verify that database policy state matches ServiceRadar settings.

#### Scenario: Settings value matches Timescale policy
- **GIVEN** MTR retention is configured
- **WHEN** ServiceRadar reads MTR retention status
- **THEN** it reports the configured retention days
- **AND** it reports whether `platform.mtr_traces` and `platform.mtr_hops` currently have matching TimescaleDB retention policies

#### Scenario: TimescaleDB extension unavailable
- **GIVEN** TimescaleDB metadata is unavailable or the extension is not installed
- **WHEN** ServiceRadar reads or reconciles MTR retention status
- **THEN** it returns a degraded status with a clear reason
- **AND** it does not fail unrelated MTR history reads solely because policy metadata could not be inspected
