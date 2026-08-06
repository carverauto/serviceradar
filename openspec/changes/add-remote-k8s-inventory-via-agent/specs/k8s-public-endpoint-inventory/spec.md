## ADDED Requirements

### Requirement: Inventory supports agent_spool publish mode for remote delivery
The public endpoint inventory collector SHALL support a publish mode that writes the current snapshot to a local spool for pickup by `serviceradar-agent`, in addition to direct NATS publish for co-located installs. Publish modes SHALL be mutually exclusive per collector instance.

#### Scenario: Remote install uses agent_spool
- **WHEN** the collector is configured with publish mode `agent_spool`
- **THEN** each successful snapshot rebuild atomically updates a spool artifact (for example `latest.json`) under the configured spool directory
- **AND** the collector does not require in-cluster NATS connectivity

#### Scenario: Co-located install can still use NATS
- **WHEN** the collector is configured with publish mode `nats`
- **THEN** snapshots are published to the configured JetStream subject as today
- **AND** agent_spool is not required for that instance

#### Scenario: Unchanged snapshot skips spool rewrite noise
- **WHEN** a rebuild produces a content-identical snapshot to the last successful publish
- **THEN** the collector may skip rewriting the spool (or equivalent) while still updating health/metrics that the watch is alive

### Requirement: Remote inventory snapshots retain durable cluster_id
Snapshots delivered via the agent path SHALL continue to include the operator-configured `cluster_id` so multi-cluster SRQL and ownership rows remain disambiguated.

#### Scenario: Two remote clusters do not collide
- **WHEN** cluster A publishes with `cluster_id=acme-prod-a` and cluster B with `cluster_id=acme-prod-b`
- **THEN** `platform.public_endpoints_current` (or equivalent) retains separate ownership rows keyed such that queries can filter by `cluster_id`
- **AND** soft-delete / reassignment for one cluster does not clear the other

### Requirement: Supported remote install is inventory plus cluster agent only
Documentation and packaging for remote clusters SHALL describe a supported footprint of public endpoint inventory plus a cluster-scoped agent that forwards to agent-gateway, without requiring a full ServiceRadar Helm release in that cluster.

#### Scenario: Operator deploys sensors-only footprint
- **WHEN** an operator follows the remote/SaaS install guidance
- **THEN** required in-cluster components are limited to inventory (with kube RBAC) and agent (with gateway enrollment)
- **AND** core, web-ng, CNPG, and NATS are not listed as required in the remote cluster
