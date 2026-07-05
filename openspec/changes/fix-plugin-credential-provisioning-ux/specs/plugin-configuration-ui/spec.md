# plugin-configuration-ui — deltas

> Scope note: the full provider-neutral credentials UI is owned by the
> in-flight `refactor-unified-credential-management` change (unstarted, no
> `credential-management` baseline exists yet — this change deliberately adds
> no deltas to that capability). The requirements below are scoped to plugin
> credential-rule activation and assignment-time validation.

## ADDED Requirements

### Requirement: Credential rule creation supports all modeled providers
The credential-rules UI SHALL expose the full underlying rule model — every modeled auth method (including `api_key`), every modeled purpose (including `camera_inventory` and `camera_stream`), secret creation for non-Proxmox providers, and provider presets for camera providers — so that any provider profile supported by the materializer can be activated without editing data out-of-band.

#### Scenario: Camera credential rule is creatable in the UI
- **GIVEN** an operator on the credential rules page
- **WHEN** they create a rule for provider `unifi-protect` with purpose `camera_inventory` and an `api_key` secret
- **THEN** the form SHALL offer those options and persist the rule
- **AND** the materializer SHALL produce plugin-input assignments for agents matching the rule's SRQL target query

#### Scenario: Non-Proxmox secrets are creatable inline
- **GIVEN** an operator creating a camera credential rule
- **WHEN** they need a new API-key secret
- **THEN** the UI SHALL offer inline secret creation for the rule's provider (not only Proxmox tokens and SSH keys)

### Requirement: Credential rule materialization is observable
The credential rules UI SHALL show, per rule, what the rule currently materializes — matched agents, fed plugins, last materialization time, and skip reasons — and reconcile runs SHALL emit counts rather than count-free success logs.

#### Scenario: Rule consumer visibility
- **GIVEN** an enabled credential rule
- **WHEN** the operator views the rule
- **THEN** the UI SHALL list the agents and plugins currently receiving materialized inputs from it
- **AND** SHALL show the last materialization time

#### Scenario: Silent no-op reconciles are distinguishable
- **GIVEN** a reconcile run that matched zero rules or resolved zero targets
- **WHEN** reconcile telemetry is emitted
- **THEN** the counts (rules matched, targets resolved, assignments written, skips with reasons) SHALL be included so a no-op is distinguishable from real work

### Requirement: Assignment-time credential coverage validation
Plugin config fields whose values are provided by credential-rule materialization SHALL be declared in the plugin schema and rendered as such; assigning a plugin whose materialized inputs have no enabled matching credential rule for the target agent SHALL produce a persistent, override-able warning at assignment time and in plugin health views — never only a runtime check failure.

#### Scenario: Materialized field is labeled, not hidden
- **GIVEN** a plugin schema field annotated as credential-materialized (e.g. camera `host`)
- **WHEN** the assignment form renders
- **THEN** the field SHALL display as "provided by credential rules" with the matching-rule status
- **AND** SHALL NOT render as an ordinary optional input or be silently omitted

#### Scenario: Missing rule coverage warns before runtime
- **GIVEN** an operator assigning a camera plugin to an agent with no enabled matching camera credential rule
- **WHEN** they save the assignment
- **THEN** a warning SHALL identify the missing rule coverage (provider, purpose, agent)
- **AND** the warning SHALL persist on the assignment and in plugin health until a matching rule materializes
