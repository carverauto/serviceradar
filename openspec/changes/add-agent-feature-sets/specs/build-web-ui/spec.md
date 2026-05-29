## ADDED Requirements

### Requirement: Edge Ops Add-on Catalog And Selection
The web-ng Edge Ops UI SHALL provide a surface where operators browse available
add-ons (feature sets), review their lifecycle state and required privileges, and
configure an add-on from its `config.schema.json`-driven form. The surface SHALL
reuse the existing schema-driven configuration form used for plugins. Access SHALL be
gated by an edge-management permission.

#### Scenario: Operator browses available add-ons
- **GIVEN** the control plane has imported add-ons into the catalog
- **WHEN** an operator opens the Edge Ops add-ons surface
- **THEN** the UI SHALL list available add-ons with name, version, lifecycle state, and whether elevated privileges are required
- **AND** staged or revoked add-ons SHALL be shown but SHALL NOT be selectable

#### Scenario: Operator configures an add-on from its schema
- **GIVEN** an approved add-on with a configuration schema
- **WHEN** an operator opens its configuration form
- **THEN** the UI SHALL render fields from the add-on's `config.schema.json`
- **AND** SHALL validate input against the schema before allowing assignment

#### Scenario: Unauthorized user cannot manage add-ons
- **GIVEN** a user without the edge-management permission
- **WHEN** they attempt to open the add-on selection surface
- **THEN** access SHALL be denied

### Requirement: Edge Ops Add-on Targeting
The Edge Ops UI SHALL let operators choose which agents receive an add-on — an
individual agent or a cohort — and SHALL present a compatibility preview indicating
which targeted agents can and cannot run the add-on before the assignment is applied.
The per-agent detail view SHALL show assigned, installed, and active add-ons and any
drift between desired and observed state.

#### Scenario: Operator targets selected agents with a compatibility preview
- **GIVEN** an operator selecting an approved add-on for deployment
- **WHEN** they choose a target agent or cohort
- **THEN** the UI SHALL show which targeted agents can run the add-on and which cannot, with a reason
- **AND** applying the selection SHALL persist an assignment for the targeted agents

#### Scenario: Per-agent detail shows desired vs observed add-ons
- **GIVEN** an agent with one or more add-on assignments
- **WHEN** an operator opens the agent's detail view
- **THEN** the UI SHALL show assigned, installed, and active add-ons
- **AND** SHALL surface drift such as selected-but-unsupported or installed-but-unhealthy

#### Scenario: Deploy-time feature-set selection
- **GIVEN** an operator creating an agent onboarding package
- **WHEN** they choose an initial feature set
- **THEN** the chosen add-ons SHALL be recorded as the agent's initial assignment
