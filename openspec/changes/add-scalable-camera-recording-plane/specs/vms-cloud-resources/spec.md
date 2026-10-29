## ADDED Requirements

### Requirement: Mode-selective recording provisioning
The SaaS control plane SHALL reconcile recording placement and storage policy independently, provisioning only resources selected by the deployment and reporting desired and applied revisions separately. Self-hosted product operation SHALL not depend on SaaS provisioning.

#### Scenario: Customer-operated local-only pool is enrolled
- **WHEN** a hosted deployment registers a customer pool configured for local retention
- **THEN** Cloud SHALL retain pool ownership, supported capabilities, budgets and observed readiness without creating S3 resources
- **AND** SHALL not claim recording readiness from enrollment or chart rendering alone
- **AND** SHALL not acquire generic authority to purge customer storage

#### Scenario: Managed or customer-operated S3 pool is enrolled
- **WHEN** the selected storage policy requires S3
- **THEN** Cloud SHALL provision or explicitly adopt the destination through the existing private qualification and credential-custody contract
- **AND** SHALL preserve distinct writer, reader and deletion authority and require security denial checks before admission
- **AND** public access or unsupported endpoint capabilities SHALL prevent new admission without deleting retained media

### Requirement: Customer recorder lifecycle and recovery inventory
The control plane SHALL retain deployment-scoped customer recorder identity, assignment/grant revisions, volume lifetimes, storage bindings and preservation state across suspend, reconnect, upgrade, restore and de-enrollment.

#### Scenario: Unreachable recorder is de-enrolled
- **WHEN** an operator revokes a customer recorder that is offline
- **THEN** the system SHALL distinguish desired revocation from observed retirement and account for outstanding offline authority
- **AND** SHALL not transfer conflicting ownership or report disk cleanup merely because the database row changed
- **AND** held media, pending uploads and active exports SHALL retain an explicit disposition requirement

#### Scenario: Cloud restores a deployment with recorder pools
- **WHEN** restore or upgrade reconciles installed recording resources
- **THEN** it SHALL use retained controller and storage identities rather than assume every workload is a core Deployment
- **AND** SHALL reject unverified volume adoption and retain unresolved customer-host state
- **AND** archive bytes, local reservations, egress and optional worker usage SHALL remain separately metered without double-counting retried receipts
