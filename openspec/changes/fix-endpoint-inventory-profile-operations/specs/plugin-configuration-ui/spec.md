## ADDED Requirements

### Requirement: Endpoint Inventory Profile Setup
The settings UI SHALL present endpoint inventory assignment as a profile-driven workflow that defaults to SRQL targeting and hides manual assignment behind an advanced override path.

#### Scenario: Operator creates simple endpoint inventory profile
- **GIVEN** an operator opens endpoint inventory setup
- **WHEN** no profile exists
- **THEN** the UI SHALL offer a primary workflow with an SRQL target query defaulted to `in:devices`
- **AND** the UI SHALL NOT require raw JSON, package-manager paths, or manual agent selection to create the profile

#### Scenario: Manual assignment is advanced override
- **GIVEN** an operator opens endpoint inventory assignment controls
- **WHEN** they choose manual per-agent assignment
- **THEN** the UI SHALL label the assignment as an advanced override
- **AND** any resulting assignment SHALL show that it overrides profile ownership

### Requirement: Endpoint Inventory Profile Preview
The settings UI SHALL show a preview report before enabling or reconciling an endpoint inventory profile.

#### Scenario: Preview reports deployment coverage
- **GIVEN** an operator previews an endpoint inventory profile
- **WHEN** the profile target query matches devices
- **THEN** the UI SHALL show matched devices, resolved agents, eligible agents, skipped targets, and skip reasons
- **AND** it SHALL distinguish devices with no enrolled agent from agents that are incompatible or offline

#### Scenario: Preview rejects unsafe broad enablement
- **GIVEN** a profile target query matches more targets than the configured preview cap
- **WHEN** the operator previews the profile
- **THEN** the UI SHALL show the cap and the truncated count
- **AND** it SHALL require an explicit confirmation before enablement or reconciliation can proceed

### Requirement: Endpoint Inventory Advanced Configuration
The endpoint inventory UI SHALL keep recommended defaults visible and move low-level collector details into an Advanced section.

#### Scenario: Recommended setup hides low-level fields
- **GIVEN** an operator creates an endpoint inventory profile
- **WHEN** they use the recommended setup flow
- **THEN** package-manager database paths, spool paths, raw args, raw params JSON, max output bytes, and force-full-scan interval SHALL be hidden behind Advanced controls

#### Scenario: Advanced values remain inspectable
- **GIVEN** an operator opens Advanced controls
- **WHEN** they inspect endpoint inventory configuration
- **THEN** the UI SHALL show the effective low-level values and their defaults
- **AND** saving invalid values SHALL return field-level validation errors

### Requirement: Endpoint Inventory Assignment Provenance
The UI SHALL show whether endpoint inventory is assigned by profile, manual override, or not assigned for each relevant agent.

#### Scenario: Agent assignment shows profile provenance
- **GIVEN** an agent has an endpoint inventory assignment materialized by an add-on profile
- **WHEN** an operator views the agent add-ons page or endpoint inventory setup coverage
- **THEN** the UI SHALL show the source profile, last reconcile time, and assignment state

#### Scenario: Agent skipped by profile shows reason
- **GIVEN** an endpoint inventory profile matched a device but skipped the associated agent
- **WHEN** an operator inspects profile coverage
- **THEN** the UI SHALL show the skipped agent and the reason

### Requirement: Producer Schedule Settings Are Generated From Package Contracts
The settings UI SHALL render recurring producer schedule controls from package-declared schedule contracts rather than provider-specific LiveView code.

#### Scenario: Advisory feed plugin exposes scheduler requirements
- **GIVEN** an approved Wasm plugin or native add-on package declares a producer schedule contract
- **WHEN** an operator opens the vulnerability feed settings page
- **THEN** the UI SHALL show the package schedule with its label, description, required settings, credential refs, default cadence, and allowed cadence bounds
- **AND** the UI SHALL NOT hard-code CISA, NVD, VulnCheck, OSV, or other provider-specific forms

#### Scenario: Operator updates package-driven schedule
- **GIVEN** a package-driven producer schedule is visible in settings
- **WHEN** the operator enables it and saves cadence, target assignment, credentials, or run parameters
- **THEN** the UI SHALL persist those values to the generic schedule state
- **AND** it SHALL show next due time, last run time, last status, last command id, and last error when available

#### Scenario: Operator triggers run now
- **GIVEN** a package-driven producer schedule has a valid target assignment
- **WHEN** the operator clicks Run now
- **THEN** the UI SHALL enqueue a one-shot producer run through the same generic scheduler/commandbus path
- **AND** it SHALL show dispatch success or the actionable reason dispatch was skipped
