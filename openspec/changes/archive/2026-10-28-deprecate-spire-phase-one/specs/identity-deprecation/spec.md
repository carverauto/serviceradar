## ADDED Requirements

### Requirement: Phase-one SPIRE deprecation preserves explicit compatibility

ServiceRadar SHALL mark SPIFFE/SPIRE runtime support deprecated while preserving explicitly configured SPIRE behavior during phase one.

#### Scenario: Deprecated runtime startup
- **WHEN** a Go, Rust or Elixir component starts with an effective `spiffe` security mode or `workload_api` certificate selector
- **THEN** it emits a WARN-level deprecation notice before attempting a Workload API connection
- **AND** the notice directs operators to the migration guide without exposing credentials or tokens
- **AND** the existing configured runtime path remains available

#### Scenario: Supported certificate mode
- **WHEN** a component starts with mTLS or filesystem certificate configuration
- **THEN** it does not emit a SPIRE deprecation warning solely because its certificate contains a `spiffe://` URI SAN

### Requirement: Neutral Helm configuration retains legacy deployment identity

The Helm chart SHALL resolve explicit neutral configuration ahead of legacy SPIRE configuration while preserving legacy effective resource identities when neutral overrides are absent.

#### Scenario: Account and trust-domain overrides
- **GIVEN** a non-blank `serviceAccounts.<component>` or deployment `trustDomain` override
- **WHEN** the chart renders a component without a higher-precedence component-specific trust-domain override
- **THEN** the neutral value wins over the corresponding `spire.*` fallback
- **AND** workload, RBAC, allow-list and registration identities use the same resolved account

#### Scenario: Legacy-only database configuration
- **GIVEN** an installation configured with legacy `spire.postgres.*` cluster settings and no neutral user override
- **WHEN** phase-one chart templates render
- **THEN** shipped `cnpg.*` defaults do not silently rename the active cluster, change its namespace, replace its credential reference or render a second cluster

#### Scenario: Default chart and explicit SPIRE notice
- **WHEN** default Helm values are rendered, including a blank `kv.secMode`
- **THEN** core datasvc security defaults to `mtls`
- **AND** default workloads contain no SPIRE socket mounts or SPIRE resources
- **WHEN** SPIRE or a deprecated SPIFFE/Workload API mode is explicitly enabled
- **THEN** Helm NOTES displays a deprecation warning and migration-guide reference

### Requirement: Newly created onboarding packages default to mTLS

ServiceRadar SHALL default new onboarding packages to `mtls` consistently across Ash, the database column default, the API and CLI while retaining existing and explicitly requested `spire` packages during phase one.

#### Scenario: Mode omitted
- **WHEN** a caller creates a new package without a security mode through the API, Ash, CLI or database default
- **THEN** the stored package mode is `mtls`

#### Scenario: Existing and explicit SPIRE packages
- **GIVEN** an existing `spire` package or a new create request explicitly selecting `spire`
- **WHEN** phase-one default migration and package handling run
- **THEN** existing rows retain their mode and remain readable
- **AND** the explicit `spire` request remains accepted

### Requirement: Deprecation documentation preserves the mTLS identity contract

ServiceRadar SHALL document deployment-managed mTLS as its supported model and provide a SPIRE migration guide without renaming the existing mTLS identity fields or certificate URI SANs.

#### Scenario: Database transition and cleanup guide
- **WHEN** an operator reads the migration guide
- **THEN** it distinguishes the application database from SPIRE's datastore
- **AND** it requires successful database recovery and service connectivity verification before cleanup
- **AND** it identifies manual SPIRE CRD, registration, webhook/RBAC, secret and PVC cleanup as a separate operation

#### Scenario: URI naming remains supported
- **WHEN** existing mTLS certificates and identity consumers use `spiffe://` names, `spiffe_identity` or `SPIFFE_CERT_DIR`
- **THEN** phase one preserves their names and behavior
- **AND** historical archived records remain unchanged
