# serviceradar-k8s-edge

Helm chart for **Kubernetes edge sensors only** — for clusters that do **not**
run the full ServiceRadar platform.

Deploys:

| Component | Purpose |
|---|---|
| `serviceradar-agent` | Outbound mTLS to **agent-gateway** (central or SaaS) |
| `serviceradar-k8s-inventory` | Read-only kube API inventory of public VIP / Gateway ownership |

Does **not** deploy: core, web-ng, NATS, CNPG, agent-gateway, SPIRE, flow
collectors, or anything that requires an in-cluster control plane.

## When to use this chart

| Situation | Chart |
|---|---|
| Full ServiceRadar in the cluster (demo, self-host all-in-one) | `helm/serviceradar` |
| Customer / SaaS cluster: sensors only, gateway elsewhere | **`helm/serviceradar-k8s-edge`** (this chart) |
| 50 clusters, one central ServiceRadar or serviceradar.cloud | This chart × N clusters |

## Architecture

```text
Customer cluster                         Platform (self-host or SaaS)
┌──────────────────────────────┐         ┌─────────────────────────┐
│  Deployment (1 pod)          │         │  agent-gateway          │
│   ├─ k8s-inventory (SA+RBAC) │  mTLS   │       │                 │
│   └─ agent  ─────────────────┼────────►│       ▼                 │
│        shared emptyDir spool │         │  NATS → core → SRQL     │
└──────────────────────────────┘         └─────────────────────────┘
```

Inventory watches the apiserver; the agent never needs inventory RBAC. Agent
identity is the enrollment Secret (edge package), not the ServiceAccount.

## Prerequisites

1. **Outbound** connectivity from the cluster to agent-gateway.
2. **Edge enrollment** materials (CA + agent cert/key) from ServiceRadar
   onboarding / edge package.
3. Kubernetes RBAC permission to create a ClusterRole (or use
   `k8sInventory.rbac.scope=namespace` with an allow-list).

## Install

```bash
# 1) Namespace + enrollment secret
kubectl create namespace serviceradar-edge
kubectl -n serviceradar-edge create secret generic sr-edge-agent-mtls \
  --from-file=root.pem=./root.pem \
  --from-file=agent.pem=./agent.pem \
  --from-file=agent-key.pem=./agent-key.pem

# 2) Customer values (see values-example.yaml)
cat > my-values.yaml <<'EOF'
clusterId: acme-prod-eks
agent:
  gatewayAddress: "agent-gateway.example.com:50052"
  gatewayServerName: "serviceradar-agent-gateway"
  existingTlsSecret: "sr-edge-agent-mtls"
  agentId: "acme-prod-eks-edge"
  partitionId: "acme-prod"
k8sInventory:
  enabled: true
  publishMode: agent_spool
EOF

# 3) Install
helm upgrade --install acme-edge ./helm/serviceradar-k8s-edge \
  -n serviceradar-edge --create-namespace \
  -f my-values.yaml
```

## Required values

| Value | Description |
|---|---|
| `clusterId` | Durable multi-cluster key (required if inventory enabled) |
| `agent.gatewayAddress` | `host:port` of agent-gateway |
| `agent.existingTlsSecret` | Secret with enrollment PEM files |
| `agent.agentId` / `partitionId` | Must match enrollment |

## Inventory options

```yaml
k8sInventory:
  enabled: true
  publishMode: agent_spool   # forward via co-located agent (default for this chart)
  namespaces: []             # empty = all; or list edge + app namespaces
  gatewayAPI:
    enabled: true
  rbac:
    scope: cluster           # or namespace (requires namespaces allow-list)
```

## Verify

```bash
kubectl -n serviceradar-edge get pods,sa,clusterrole | grep -E 'edge|inventory|agent'
kubectl -n serviceradar-edge logs deploy/acme-edge -c k8s-inventory --tail=50
kubectl -n serviceradar-edge logs deploy/acme-edge -c agent --tail=50
```

On the platform (once agent_spool path is fully wired — see OpenSpec
`add-remote-k8s-inventory-via-agent`):

```text
in:public_endpoints cluster_id:acme-prod-eks limit:20
```

## Status of the agent_spool data path

| Layer | Status |
|---|---|
| Helm sensors-only install | **This chart** |
| Inventory `PUBLISH_MODE=agent_spool` writer | **Implemented** (`go/pkg/k8sinventory` SpoolPublisher) |
| Agent spool reader → status push | **Implemented** (`k8s_public_endpoints` agent config) |
| Gateway → JetStream `inventory.k8s.*` | **Implemented** (`K8sPublicEndpointsPublisher`) |
| Co-located full chart + NATS inventory | **Supported** (`helm/serviceradar`, `publishMode: nats`) |

Deploy this chart with images that include the above code, enroll the agent,
and query:

```text
in:public_endpoints cluster_id:<your-clusterId> limit:20
```

## Related

- Operator docs: `docs/docs/k8s-public-endpoint-inventory.md`
- OpenSpec: `openspec/changes/add-remote-k8s-inventory-via-agent/`
- Full platform chart: `helm/serviceradar`
