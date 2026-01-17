# tenant-workload-orchestration Specification

## Purpose
TBD - created by archiving change add-tenant-workload-crds. Update Purpose after archive.
## Requirements
### Requirement: Tenant workload CRDs
The system SHALL provide CRDs to define per-tenant workloads and workload templates.

#### Scenario: Template and workload set declared
- **WHEN** a `TenantWorkloadTemplate` is installed
- **AND** a `TenantWorkloadSet` exists for a tenant
- **THEN** the operator recognizes the template reference and schedules the tenant workload resources

### Requirement: NATS-driven CR lifecycle
The operator SHALL consume tenant lifecycle events and create/update/delete `TenantWorkloadSet` CRs without exposing Kubernetes APIs to workloads.

#### Scenario: Tenant created event
- **WHEN** a `tenant.created` event is published
- **THEN** the operator creates or updates the tenant's `TenantWorkloadSet`
- **AND** no workload pod requires Kubernetes API access to exist

#### Scenario: Tenant deleted event
- **WHEN** a `tenant.deleted` event is published
- **THEN** the operator deletes the tenant's `TenantWorkloadSet`
- **AND** all tenant workload resources are removed

### Requirement: SPIFFE identity per tenant workload
The operator SHALL provision SPIFFE identities that encode tenant ownership for each workload.

#### Scenario: Workload SPIFFE identity
- **WHEN** the operator creates a tenant workload
- **THEN** it creates a ClusterSPIFFEID binding pods to a tenant-specific SPIFFE ID
- **AND** the SPIFFE ID includes the tenant identifier

### Requirement: Zen consumer defaults
The default zen-consumer workload SHALL run as a DaemonSet and SHALL NOT expose a Service.

#### Scenario: Default zen workload
- **WHEN** a tenant workload set includes `zen-consumer`
- **THEN** the operator creates a DaemonSet
- **AND** no Service is created unless explicitly requested in the template

### Requirement: Tenant-scoped NATS credentials
The operator SHALL request tenant-scoped NATS credentials and mount them into tenant workloads that require NATS access.

#### Scenario: Tenant workload NATS creds
- **WHEN** a workload template declares a NATS credential requirement
- **THEN** the operator requests tenant creds from core
- **AND** stores them in a tenant-specific Secret for the workload to mount

