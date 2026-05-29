## ADDED Requirements

### Requirement: Per-agent add-on status read model
The control plane SHALL parse the per-add-on status the agent reports in its capability
status — installed, available, active, or unhealthy, with a degradation reason and the
architecture — into the agent registry read model, keyed by agent and add-on id, and
SHALL make it queryable via SRQL where relevant. The read model SHALL reflect the most
recent reported state so the UI can reconcile desired assignments against observed
state.

#### Scenario: Reported add-on status populates the read model
- **GIVEN** an agent that reports a per-add-on status (e.g. active, version, arch) in its capability status
- **WHEN** the control plane ingests the status
- **THEN** the agent registry read model SHALL record the add-on's state, reason, and arch keyed by agent and add-on id

#### Scenario: Unhealthy add-on is observable
- **GIVEN** an agent reporting an add-on as unhealthy with a degradation reason
- **WHEN** the read model is queried for that agent
- **THEN** the add-on SHALL be reported unhealthy with its reason

#### Scenario: Add-on status is queryable via SRQL
- **WHEN** an operator queries agent add-on state via SRQL
- **THEN** the per-agent add-on status SHALL be returned from the read model
