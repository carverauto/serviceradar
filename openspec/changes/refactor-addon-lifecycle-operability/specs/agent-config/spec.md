# agent-config — deltas

## ADDED Requirements

### Requirement: Sectioned config apply with failure disposition
The agent SHALL apply control-stream configuration per section with an explicit per-section failure disposition (success, transient, permanent). A failing section SHALL NOT prevent other sections from applying in the same cycle. Transient failures defer the config version commit (so delivery retries); permanent failures record persistent state, allow the version to commit and be acknowledged, and escalate once instead of retrying identically every cycle.

#### Scenario: One failing section does not block the others
- **GIVEN** a config version whose add-on config section fails to parse (permanent failure, e.g. type-invalid `config_json`)
- **AND** its sysmon and mapper sections are valid
- **WHEN** the agent applies the config version
- **THEN** the sysmon and mapper sections SHALL be applied
- **AND** the version SHALL be committed and acknowledged with the add-on section reported as permanently failed

#### Scenario: Transient failure defers without skipping later sections
- **GIVEN** a config version whose add-on assignment section fails transiently (e.g. artifact fetch timeout)
- **WHEN** the agent applies the config version
- **THEN** all remaining sections SHALL still be evaluated and applied in the same cycle
- **AND** the version commit SHALL be deferred so delivery retries the failed section

#### Scenario: Permanent failures escalate instead of retry-spamming
- **GIVEN** a section apply failure classified as permanent (e.g. schema parse error)
- **WHEN** subsequent config refresh cycles run
- **THEN** the agent SHALL NOT re-attempt the identical failing payload on every cycle
- **AND** the failure SHALL be reported once per config version at error level with a persistent status, not per-cycle warn/info logs

### Requirement: Config acknowledgement is persisted and wedge detection alerts
Core SHALL persist per-agent config version acknowledgements with per-section apply status, and SHALL surface an agent as config-unhealthy when it stops acknowledging config versions while connected, or when it reports a permanently failing section.

#### Scenario: Agent stops acking config versions
- **GIVEN** an agent that has not acknowledged any config version for longer than the configured window while remaining connected
- **WHEN** core evaluates agent config health
- **THEN** the agent SHALL be marked config-unhealthy with the last-acked version and elapsed time
- **AND** the condition SHALL be visible on the agent detail and fleet views and emit a health event

#### Scenario: Failing section is visible verbatim
- **GIVEN** an agent reporting a permanently failing config section
- **WHEN** an operator views the agent in the UI
- **THEN** the failing section name and its full error message SHALL be displayed with when the failure started

#### Scenario: Config-apply failure surfaces as add-on health
- **GIVEN** an add-on whose config section permanently fails to apply while its process remains running
- **WHEN** add-on status is reported and rendered
- **THEN** the add-on SHALL be shown as unhealthy with the config-apply failure reason (parity with artifact-delivery failure statuses), not as healthy/running

### Requirement: Typed add-on config contracts on the delivery path
Add-on assignment parameters SHALL be validated and schema-coerced against the add-on package's declared config schema at delivery time before being emitted as `config_json`, and at every write path (manual assignment, profile reconciliation, package seeding). Parameters that cannot be coerced to the declared schema SHALL refuse delivery of that add-on's config with a visible per-assignment error instead of shipping payloads known to fail agent-side decoding. Agent-side decoders SHALL accept documented compatibility forms as defense in depth. CI SHALL run contract tests that decode core-emitted configuration with the actual agent/add-on decoders for every bundled add-on.

#### Scenario: Delivery path coerces schema-compatible drift
- **GIVEN** an add-on assignment storing `capture_interfaces` as a scalar string where the package schema declares an array of strings
- **WHEN** the deliverable config is generated
- **THEN** the value SHALL be coerced to a single-element string list before `config_json` encoding
- **AND** the delivered payload SHALL decode successfully with the agent's typed decoder

#### Scenario: Uncoercible params refuse delivery visibly
- **GIVEN** an add-on assignment whose params cannot be coerced to the package schema
- **WHEN** the deliverable config is generated
- **THEN** that add-on's config SHALL NOT be delivered
- **AND** the assignment SHALL show a validation error identifying the field and expected type

#### Scenario: Agent decoder tolerates documented compatibility forms
- **GIVEN** an agent receiving `capture_interfaces` as a JSON string containing a single interface name
- **WHEN** the add-on config is parsed
- **THEN** the value SHALL be coerced to a single-element string list
- **AND** the apply SHALL succeed with a compatibility notice rather than a permanent failure

#### Scenario: Contract tests cover every bundled add-on
- **GIVEN** the CI pipeline
- **WHEN** core config generation or add-on config schemas change
- **THEN** contract tests SHALL decode representative core-emitted `config_json` with the real agent-side decoders for netprobe, otel-collector, anomaly, bumblebee, endpoint-inventory, workload-identity, and rdp
- **AND** a decode failure SHALL fail CI
