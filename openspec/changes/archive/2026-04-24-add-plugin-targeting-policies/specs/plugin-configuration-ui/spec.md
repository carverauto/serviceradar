## ADDED Requirements
### Requirement: Plugin target policy authoring UI
The UI SHALL allow operators to create and manage plugin target policies using SRQL target queries.

#### Scenario: Operator configures policy with chunk settings
- **GIVEN** an operator creating a plugin target policy
- **WHEN** they provide plugin package, SRQL query, cadence, and chunk size
- **THEN** the UI SHALL validate inputs and save the policy

### Requirement: Policy preview and distribution visibility
The UI SHALL provide policy preview before enabling execution, including total target count and per-agent chunk distribution.

#### Scenario: Preview shows high-cardinality result
- **GIVEN** a policy query matching thousands of cameras
- **WHEN** preview is requested
- **THEN** the UI SHALL show total matched targets
- **AND** display estimated chunked assignments per agent

### Requirement: Policy payload schema visibility and validation
The UI SHALL surface the policy batch payload schema contract and validate template contributions against schema constraints before save.

#### Scenario: Template validation against batch schema
- **GIVEN** an operator edits policy template fields that are merged into assignment `params_json`
- **WHEN** the template violates `serviceradar.plugin_target_batch_params.v1` constraints
- **THEN** the UI SHALL block save with field-level validation errors
