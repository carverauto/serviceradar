## ADDED Requirements

### Requirement: Docker Compose remains functional with major subsystems enabled
The default Docker Compose deployment SHALL remain interactive and operational with major subsystems enabled, including diagnostics, maintenance, enrichment, and reconciliation workloads, without relying on feature disablement to preserve basic control-plane behavior.

#### Scenario: Interactive workflows remain healthy on a clean single-node deployment
- **GIVEN** a clean Docker Compose environment started with the standard compose configuration
- **AND** major subsystems remain enabled
- **WHEN** an operator loads analytics pages, submits MTR diagnostics, and agents continue sending heartbeats
- **THEN** those workflows complete without recurring database queue collapse
- **AND** the stack does not require disabling optional subsystems just to preserve usability

#### Scenario: Background job execution respects compose workload budgets
- **GIVEN** the Docker Compose stack is running with the standard background job configuration
- **WHEN** maintenance, enrichment, and reconciliation jobs are scheduled
- **THEN** their execution remains within the configured background database budget
- **AND** control-plane critical workflows retain the capacity needed to complete
