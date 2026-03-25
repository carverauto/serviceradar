## ADDED Requirements
### Requirement: Camera Analysis Worker Probe Configuration
The platform SHALL support operator-managed probe configuration for registered camera analysis workers.

#### Scenario: Worker has explicit probe endpoint override
- **WHEN** an operator configures a worker with an explicit probe endpoint URL
- **THEN** the platform uses that endpoint for active health probing

#### Scenario: Worker uses bounded probe defaults
- **WHEN** an operator does not configure explicit probe overrides for a worker
- **THEN** the platform applies bounded default probe behavior

### Requirement: Active Probing Uses Registry-Managed Probe Settings
The active probe runtime SHALL use the current probe configuration stored on the worker registry record.

#### Scenario: Probe timeout override is configured
- **WHEN** a worker has an explicit probe timeout configured
- **THEN** the platform uses that timeout for active probing of that worker
