## ADDED Requirements
### Requirement: Camera Analysis Worker Management Includes Probe Settings
The operator-facing worker management surface SHALL expose worker probe configuration alongside identity, health, and capability metadata.

#### Scenario: Operator inspects a worker
- **WHEN** an operator views a registered camera analysis worker
- **THEN** the surface shows the worker probe endpoint and timeout configuration

#### Scenario: Operator updates probe settings
- **WHEN** an operator creates or updates a registered camera analysis worker
- **THEN** the management surface accepts and persists supported probe configuration fields
