## ADDED Requirements

### Requirement: Agent-forwarded snapshots require an approved cluster binding
The system SHALL apply an agent-forwarded Kubernetes inventory snapshot only when its body `cluster_id` is bound to the gateway-authenticated agent and partition in control-plane state.

#### Scenario: Bound agent publishes its cluster
- **WHEN** an authenticated agent publishes a snapshot whose `cluster_id`, agent identity, and partition exactly match an active control-plane binding
- **THEN** EventWriter accepts the snapshot for normal reconciliation
- **AND** the accepted snapshot records the authenticated agent and partition as provenance

#### Scenario: Agent claims another cluster
- **WHEN** an authenticated agent publishes a snapshot whose body `cluster_id` is unbound or belongs to a different agent or partition
- **THEN** the system rejects the snapshot before applying inventory changes
- **AND** no endpoint row is inserted, updated, resurrected, or soft-deleted

#### Scenario: Agent-path provenance is incomplete
- **WHEN** a snapshot carries any agent-path marker but lacks a complete authenticated agent and partition identity
- **THEN** the system rejects the snapshot
- **AND** the message cannot fall back to the direct publisher path

### Requirement: Cluster ownership bindings are explicit control-plane policy
The system SHALL create, transfer, and remove Kubernetes inventory cluster ownership only through an administrator-authorized control-plane action.

#### Scenario: Snapshot content attempts to establish ownership
- **WHEN** an unbound agent reports a `cluster_id` in snapshot content, registration metadata, or heartbeat metadata
- **THEN** the system does not create or modify a cluster ownership binding

#### Scenario: Administrator replaces a cluster agent
- **WHEN** an administrator transfers a cluster binding from one enrolled agent to another
- **THEN** the replacement agent becomes the only agent authorized for that cluster and partition
- **AND** the previous agent can no longer mutate that cluster's inventory
- **AND** the transfer retains auditable actor and timestamp evidence

### Requirement: Direct inventory publishing remains a distinct trusted path
The system SHALL distinguish direct platform inventory publishers from agent-forwarded publishers without accepting caller-controlled agent provenance as a direct-publisher signal.

#### Scenario: Existing direct publisher sends inventory
- **WHEN** the supported in-cluster inventory service publishes through its platform NATS credential without an agent-path marker
- **THEN** EventWriter continues to reconcile the operator-configured `cluster_id` under the direct publisher policy

#### Scenario: Malformed agent message omits one provenance field
- **WHEN** a message includes an agent-path marker or partial agent provenance but does not satisfy the complete binding contract
- **THEN** EventWriter rejects it instead of treating it as a direct publisher message
