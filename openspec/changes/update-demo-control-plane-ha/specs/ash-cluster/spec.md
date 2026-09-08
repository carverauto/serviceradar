## ADDED Requirements
### Requirement: Replicated platform services in Kubernetes
The system SHALL support running `core`, `web-ng`, and `agent-gateway` as multi-replica platform services in Kubernetes while preserving one shared internal ERTS cluster.

#### Scenario: Three-replica control plane forms one ERTS cluster
- **GIVEN** the Helm deployment configures `core`, `web-ng`, and `agent-gateway` with three replicas each
- **WHEN** the pods start in Kubernetes
- **THEN** all healthy replicas SHALL join the same internal ERTS cluster
- **AND** headless-service discovery SHALL continue to resolve the participating nodes
- **AND** cluster health views SHALL report the full connected control-plane membership

### Requirement: Core singleton coordination in replicated deployments
The system SHALL ensure that replicated `core` deployments expose only one active owner for coordinator-only responsibilities at a time.

#### Scenario: Only one core replica owns coordinator duties
- **GIVEN** three healthy `core` replicas are running in the same Kubernetes cluster
- **WHEN** the cluster elects or assigns the active coordinator
- **THEN** exactly one `core` replica SHALL run coordinator-only responsibilities
- **AND** non-coordinator `core` replicas SHALL remain available for clustered reads, RPC, and other non-singleton work

#### Scenario: Coordinator ownership transfers on pod loss
- **GIVEN** a replicated `core` deployment with one active coordinator
- **WHEN** the coordinator pod becomes unavailable
- **THEN** another healthy `core` replica SHALL assume coordinator ownership
- **AND** the system SHALL avoid duplicate active coordinators during the transition
