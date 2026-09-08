## ADDED Requirements

### Requirement: Cluster-plane inventory is isolated from node-plane agents
When ServiceRadar collects Kubernetes control-plane inventory for public endpoints, the architecture SHALL isolate Kubernetes API access to a dedicated cluster-plane component. Edge and host agents that perform netprobe, workload-identity, or general host monitoring MUST NOT obtain cluster-scoped Kubernetes API credentials for that inventory function.

#### Scenario: Node plane remains without apiserver inventory token
- **WHEN** public endpoint inventory is deployed in a Kubernetes cluster
- **THEN** host agents on worker nodes do not receive the inventory ServiceAccount token or equivalent apiserver credentials for ownership watches

#### Scenario: Cluster plane owns inventory watches
- **WHEN** public endpoint inventory is enabled
- **THEN** inventory watches are performed by the dedicated inventory Deployment (or equivalent few-replica cluster-plane process), not by per-node agent processes
