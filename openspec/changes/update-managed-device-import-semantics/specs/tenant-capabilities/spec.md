## MODIFIED Requirements
### Requirement: The runtime exports plan-relevant usage metrics
ServiceRadar SHALL export Prometheus metrics for plan-relevant runtime usage without embedding SaaS pricing logic into those metrics.

#### Scenario: Active managed-device usage is observed
- **WHEN** the runtime exposes Prometheus metrics
- **THEN** it includes a canonical metric for current active managed-device count
- **AND** the count SHALL include devices with `is_managed = true` and `is_active = true`
- **AND** the count SHALL exclude inactive devices and unmanaged devices
- **AND** the metric definition is stable enough for external systems to use as the source of truth for plan utilization

#### Scenario: Collector usage is observed
- **WHEN** the runtime exposes Prometheus metrics
- **THEN** it includes metrics for current collector inventory or enabled collector counts where practical
- **AND** those metrics can be consumed by external systems without requiring direct database access

### Requirement: Managed-device limits surface advisory warnings
ServiceRadar SHALL support deployment-supplied managed-device limits as advisory runtime inputs without embedding commercial plan logic into OSS.

#### Scenario: Active managed-device count exceeds a configured limit
- **WHEN** the runtime receives an external managed-device limit
- **AND** the canonical active managed-device count exceeds that limit
- **THEN** operator-facing UI surfaces an advisory warning
- **AND** the warning uses the same canonical active managed-device count exported for runtime usage visibility

#### Scenario: No managed-device limit is configured
- **WHEN** the runtime starts without an external managed-device limit
- **THEN** the runtime does not warn about managed-device caps by default
