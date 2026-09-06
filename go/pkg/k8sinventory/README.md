# k8sinventory

Discovers **public / edge Kubernetes endpoint ownership** and builds
**VIP → backend socket** correlation hints.
Optional Node readiness collection is described in the
[operator RBAC guide](../../../docs/docs/k8s-public-endpoint-inventory.md#helm-serviceaccount-and-rbac).

**Operator documentation:** [docs/docs/k8s-public-endpoint-inventory.md](../../../docs/docs/k8s-public-endpoint-inventory.md)
(ServiceAccount/RBAC via Helm, Argo CD notes, IR workflow).

## Phases

| Phase | Status | What |
|---|---|---|
| A | Done | Pure `BuildSnapshot`, unit tests, `snapshot` CLI (no NATS) |
| B | Done (collector) | Debounced controller, informers, publish modes, Helm optional |
| C | Done | Core EventWriter, `public_endpoints_current`, SRQL, VIP→attributed flow join |

No host-agent kube API access. Cluster-plane Deployment only.

**Scope:** default API visibility is **cluster-wide** (Services / EndpointSlices /
Gateway API). That is inventory of *public edges*, not packet capture. Customer
deploy guidance (co-located vs multi-cluster, namespace allow-lists, `clusterId`)
lives in the operator doc above.

## What it answers

Given a public flow destination such as `198.51.100.10:22`:

1. **Ownership** — LoadBalancer Service and/or Gateway API route
2. **Backends** — EndpointSlice pod/node/port
3. **Correlation hints** — public NetFlow tuple → post-DNAT socket

## Tests (no cluster / no NATS)

```bash
# Preferred (CI / monorepo)
bazel test //go/pkg/k8sinventory:k8sinventory_test

# Local go (optional)
go test ./go/pkg/k8sinventory/ -count=1
```

## CLI

```bash
go build -o k8s-inventory ./go/cmd/k8s-inventory

# one-shot dump
./k8s-inventory snapshot --cluster-id demo --ip 198.51.100.10 --port 22

# long-running with stdout publish (validates watch/rebuild without NATS)
PUBLISH_MODE=stdout CLUSTER_ID=demo K8S_INVENTORY_METRICS_ADDR=:9109 \
  ./k8s-inventory run
```

### Env for `run`

| Variable | Default | Notes |
|---|---|---|
| `CLUSTER_ID` | required | Durable per cluster (SRQL / multi-cluster key) |
| `PUBLISH_MODE` | `nats` | `nats` \| `agent_spool` \| `stdout` \| `none` |
| `K8S_INVENTORY_SUBJECT` | `inventory.k8s.public_endpoints` | Used for NATS subject; informational for agent_spool |
| `K8S_INVENTORY_SPOOL_DIR` | `/var/lib/serviceradar/k8s-inventory/spool` | Required for `agent_spool` (shared with agent) |
| `NATS_HOSTPORT` | required if nats | e.g. `tls://serviceradar-nats:4222` |
| `NATS_STREAM` | `k8s_inventory` | |
| `K8S_INVENTORY_NAMESPACES` | empty = all | Comma-separated allow-list |
| `K8S_INVENTORY_GATEWAY_API` | `true` | soft-fail if CRDs missing |
| `K8S_INVENTORY_RESYNC` | `5m` | |
| `K8S_INVENTORY_DEBOUNCE` | `2s` | |
| `K8S_INVENTORY_METRICS_ADDR` | `:9109` | `/healthz` `/readyz` `/metrics` `/snapshot` |

## Helm

```yaml
k8sInventory:
  enabled: false   # default
  clusterId: acme-prod-eks
  # namespaces: [envoy-gateway-system, production]  # optional allow-list
```

Demo enables via `values-demo.yaml` (`clusterId: demo`, all namespaces).
Customer installs: see operator doc “Customer deployment”. Requires image
`serviceradar-k8s-inventory` and runtime certs (`k8s-inventory.pem`). NATS ACL
allows `inventory.k8s.>`.
