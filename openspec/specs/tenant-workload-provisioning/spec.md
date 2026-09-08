# tenant-workload-provisioning Specification

## Purpose
TBD - created by archiving change add-tenant-workload-operator. Update Purpose after archive.
## Requirements
### Requirement: Tenant lifecycle events for provisioning
The system SHALL publish tenant lifecycle events to a JetStream stream so the Kubernetes operator can reconcile per-tenant workloads.

#### Scenario: Tenant created event published
- **WHEN** a tenant is created
- **THEN** the system SHALL publish a `tenant.created` event to the provisioning stream
- **AND** the event SHALL include tenant id, tenant slug, and desired workload flags

#### Scenario: Tenant deleted event published
- **WHEN** a tenant is deleted
- **THEN** the system SHALL publish a `tenant.deleted` event to the provisioning stream
- **AND** the event SHALL include tenant id and tenant slug

### Requirement: Operator NATS account provisioning

The platform bootstrap process SHALL create a dedicated NATS account for the tenant workload operator with least-privilege access to the provisioning stream.

#### Scenario: Operator connects to provisioning stream
- **GIVEN** the operator NATS account is created
- **WHEN** the operator starts
- **THEN** it SHALL authenticate with the operator credentials
- **AND** it SHALL subscribe to the tenant provisioning stream only

#### Scenario: Provisioning credentials stay least-privilege
- **GIVEN** the platform signs NATS credentials for a workload operator or tenant workload
- **WHEN** the request attempts to widen access beyond the approved provisioning or tenant scope
- **THEN** the signing request SHALL be rejected
- **AND** the returned credentials SHALL remain least-privilege for the intended workload role

### Requirement: Operator reconciles tenant workloads
The tenant workload operator SHALL reconcile per-tenant Kubernetes workloads based on lifecycle events.

#### Scenario: Tenant create triggers workload deployment
- **WHEN** a `tenant.created` event is received
- **THEN** the operator SHALL create or update the per-tenant agent-gateway and zen consumer workloads
- **AND** required Services and configuration resources SHALL be present

#### Scenario: Tenant delete triggers cleanup
- **WHEN** a `tenant.deleted` event is received
- **THEN** the operator SHALL remove the per-tenant workloads
- **AND** tenant-scoped Secrets and configuration resources SHALL be removed

### Requirement: Operator retrieves tenant artifacts from core
The operator SHALL request tenant-specific artifacts from core and store them as Kubernetes Secrets for the tenant workloads.

#### Scenario: Operator provisions tenant secrets
- **WHEN** the operator reconciles a tenant workload
- **THEN** it SHALL call core APIs for mTLS certificates and NATS credentials
- **AND** it SHALL store the artifacts in Kubernetes Secrets mounted by the workloads

### Requirement: Docker single-tenant behavior
Non-Kubernetes deployments SHALL run a single-tenant stack without the tenant workload operator.

#### Scenario: Docker compose uses static workloads
- **GIVEN** a Docker Compose deployment
- **WHEN** the stack is started
- **THEN** a single platform tenant gateway and zen consumer SHALL run with static configuration
- **AND** no tenant provisioning events are required

