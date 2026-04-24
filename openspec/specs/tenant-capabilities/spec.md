# tenant-capabilities Specification

## Purpose
TBD - created by archiving change add-tenant-usage-metrics-and-capability-hooks. Update Purpose after archive.
## Requirements
### Requirement: The runtime exports plan-relevant usage metrics
ServiceRadar SHALL export Prometheus metrics for plan-relevant runtime usage without embedding SaaS pricing logic into those metrics.

#### Scenario: Managed-device usage is observed
- **WHEN** the runtime exposes Prometheus metrics
- **THEN** it includes a canonical metric for current managed-device count
- **AND** the metric definition is stable enough for external systems to use as the source of truth for plan utilization

#### Scenario: Collector usage is observed
- **WHEN** the runtime exposes Prometheus metrics
- **THEN** it includes metrics for current collector inventory or enabled collector counts where practical
- **AND** those metrics can be consumed by external systems without requiring direct database access

### Requirement: The runtime accepts generic capability flags
ServiceRadar SHALL accept externally supplied capability flags that enable or disable selected product surfaces without requiring SaaS-specific billing logic inside OSS.

#### Scenario: No external capability set is supplied
- **WHEN** the runtime starts without deployment-supplied capability flags
- **THEN** it preserves current OSS behavior by default

#### Scenario: Collector capability is disabled
- **WHEN** the runtime receives a capability set with collector onboarding disabled
- **THEN** collector-related UI entry points are hidden or disabled
- **AND** collector-related backend actions are rejected

### Requirement: Capability flags are enforced in both UI and backend paths
ServiceRadar SHALL not rely on UI-only hiding for plan-restricted features.

#### Scenario: A disallowed collector action is submitted directly
- **WHEN** a client attempts a collector-related backend action while the relevant capability is disabled
- **THEN** the backend rejects the action
- **AND** the system does not rely only on UI hiding to enforce that restriction

### Requirement: Managed-device limits surface advisory warnings
ServiceRadar SHALL support deployment-supplied managed-device limits as advisory runtime inputs without embedding commercial plan logic into OSS.

#### Scenario: Managed-device count exceeds a configured limit
- **WHEN** the runtime receives an external managed-device limit
- **AND** the canonical managed-device count exceeds that limit
- **THEN** operator-facing UI surfaces an advisory warning
- **AND** the warning uses the same canonical managed-device count exported for runtime usage visibility

#### Scenario: No managed-device limit is configured
- **WHEN** the runtime starts without an external managed-device limit
- **THEN** the runtime does not warn about managed-device caps by default

### Requirement: OSS remains neutral about commercial plan policy
ServiceRadar SHALL keep billing, pricing, and commercial plan resolution outside the OSS runtime.

#### Scenario: External SaaS policy consumes runtime metrics
- **WHEN** an external control plane consumes usage metrics and supplies capability flags
- **THEN** the runtime honors those generic inputs
- **AND** it does not require OSS to know the names or prices of commercial plans
