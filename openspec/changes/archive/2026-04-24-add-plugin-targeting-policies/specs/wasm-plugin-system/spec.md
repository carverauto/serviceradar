## MODIFIED Requirements
### Requirement: Plugin Assignment and Distribution
The control plane SHALL allow assigning plugin packages to agents and SHALL deliver assignments through the agent config response.

The control plane SHALL support policy-derived batched assignments where each assignment targets a bounded list of devices for one agent.

#### Scenario: Policy-derived batched assignment delivery
- **GIVEN** an enabled plugin target policy that matches many devices
- **WHEN** reconciliation runs
- **THEN** the control plane SHALL produce one or more assignments per agent with bounded `targets[]` batches
- **AND** the next `AgentConfigResponse` SHALL include those batched assignments

#### Scenario: Deterministic chunk reconciliation
- **GIVEN** unchanged policy query results for an agent
- **WHEN** reconciliation runs again
- **THEN** assignment keys for unchanged chunks SHALL remain stable
- **AND** unchanged assignments SHALL NOT be rewritten

#### Scenario: Batched assignment payload conforms to schema and size guardrails
- **GIVEN** a policy-derived assignment generated for an agent
- **WHEN** the control plane serializes `params_json`
- **THEN** the payload SHALL conform to `serviceradar.plugin_target_batch_params.v1`
- **AND** payload generation SHALL enforce configured size limits by reducing chunk size when needed
