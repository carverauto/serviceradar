## ADDED Requirements

### Requirement: Remote cluster sensors use agent-gateway, not platform ERTS or CNPG
When customers deploy Kubernetes public endpoint inventory outside a full ServiceRadar install, the remote cluster SHALL communicate with the platform only through the existing edge path: outbound mTLS gRPC from `serviceradar-agent` to `agent-gateway`. Remote clusters MUST NOT require ERTS membership, direct CNPG access, or an in-cluster NATS JetStream hub for inventory delivery.

#### Scenario: SaaS customer cluster has no ServiceRadar control plane
- **WHEN** a customer runs only `serviceradar-k8s-inventory` and a cluster-scoped `serviceradar-agent` in their Kubernetes cluster
- **AND** the agent is enrolled against ServiceRadar Cloud or a central self-hosted gateway
- **THEN** public endpoint inventory reaches central ingest without deploying core, web-ng, CNPG, or NATS in that customer cluster

#### Scenario: Edge remains outbound-only
- **WHEN** remote inventory is enabled
- **THEN** the customer network initiates connections to agent-gateway
- **AND** the platform does not require inbound access to the customer apiserver for inventory publish

### Requirement: Cluster-plane inventory stays isolated from node-plane agents on the remote path
When inventory is delivered via the agent path, Kubernetes API credentials for public endpoint watches SHALL remain confined to the inventory Deployment (or equivalent cluster-plane process). Node-plane / DaemonSet agents MUST NOT receive inventory ServiceAccount tokens solely because they forward host telemetry.

#### Scenario: Host DaemonSet agents do not get inventory RBAC
- **WHEN** a cluster runs host agents as a DaemonSet and inventory as a Deployment
- **THEN** only the inventory workload’s ServiceAccount is bound to inventory list/watch RBAC
- **AND** DaemonSet agents continue without cluster-scoped Services/EndpointSlices/Gateway watches for inventory

#### Scenario: Cluster agent Deployment may co-locate with inventory without holding kube inventory RBAC
- **WHEN** a single-replica cluster agent is deployed solely to forward inventory spools to agent-gateway
- **THEN** that agent identity is used for gateway mTLS enrollment
- **AND** that agent does not require the inventory ClusterRole to perform the forward
