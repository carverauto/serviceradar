# tenant-capabilities — spec deltas

## ADDED Requirements

### Requirement: Cold-tier capability follows the deployment-supplied configuration pattern
The tiered-telemetry cold tier SHALL be activated exclusively by deployment-supplied configuration (object-store location and credentials, analytics-head connection, per-table windows), following the same pattern as other externally supplied capability flags: when the configuration is absent, the runtime preserves current behavior in full; when present, the runtime honors it without knowledge of any commercial policy. OSS code and specs SHALL NOT reference plan names or commercial gating for this capability.

#### Scenario: Externally managed deployment
- **WHEN** an external control plane supplies cold-tier configuration to a deployment it manages
- **THEN** the runtime activates the cold tier for the configured tables without any control-plane dependency at runtime

#### Scenario: Self-managed deployment without configuration
- **WHEN** a self-managed deployment supplies no cold-tier configuration
- **THEN** behavior is identical to a build without this capability, and nothing in the product implies a missing entitlement

### Requirement: Per-table retention windows are the projection contract; the scalar hot-retention variable is deprecated
The runtime SHALL honor per-table retention environment variables as the sole retention-window projection contract, introducing them for registry tables that lack one and decoupling them from configuration keys shared with non-registry tables (so projecting a registry table's window never silently resizes another table's retention). The scalar `SERVICERADAR_RETENTION_HOT_DAYS` SHALL be deprecated and never consumed — mapping from external policy (plans) to per-table windows is the projecting system's responsibility. On cold-configured deployments, applying a shorter per-table retention window SHALL additionally require the cold completeness frontier to cover the range being given up before any drop occurs.

#### Scenario: External system projects retention
- **WHEN** an external system sets per-table retention environment variables
- **THEN** the runtime applies them per table through the fenced retention path

#### Scenario: Retention shortened on a cold-enabled deployment
- **WHEN** a per-table hot window is reduced
- **THEN** chunks in the newly-expired range are dropped only after they are verified in the cold tier
