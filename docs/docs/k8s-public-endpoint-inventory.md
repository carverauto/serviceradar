---
sidebar_position: 10
title: Kubernetes Public Endpoint Inventory
---

# Kubernetes Public Endpoint Inventory

Public endpoint inventory answers **who owns this public IP or hostname:port?**
in a Kubernetes cluster—without running ad-hoc `kubectl get svc -A` during an
incident.

Typical IR question:

> We see NetFlow from Colombia to `198.51.100.10:22`. Is that a host shell,
> a git SSH listener, or something else?

With inventory enabled, the collector maps that VIP to the Envoy
Gateway LoadBalancer, the `ssh` Gateway listener / TCPRoute, and backend
pod sockets. Core joins those hints with NetFlow + netprobe so Attributed
Flows can show process **and** Service/Gateway owner.

Use this guide with [NetFlow](./netflow.md), [Host Network Visibility
(netprobe)](./netprobe.md), [Workload Identity](./workload-identity.md), and
[Helm configuration](./helm-configuration.md).

## What it is (and is not)

| It is | It is not |
|---|---|
| A **cluster-plane API inventory** of public Services / Gateways / ExternalIPs | A traffic sniffer or CNI tap |
| Ownership: Service, Gateway, route, backend EndpointSlice targets | Full SSH / payload inspection |
| Correlation hints (`VIP:port` → `podIP:targetPort`) for DNAT | Per-namespace by default (see scope below) |
| Input to **attributed flow** auto-join when netprobe is present | A host-agent feature |
| Optional Helm component (`k8sInventory.enabled`) | Enabled by default |

**Security model:** only the in-cluster `serviceradar-k8s-inventory` Deployment
holds Kubernetes API credentials. Host agents, netprobe, and workload-identity
**do not** get kube API access for this feature (same split as Datadog Cluster
Agent / Dynatrace ActiveGate-style designs).

### Scope: what “cluster-wide” means

The collector **does not observe network packets**. It watches the Kubernetes
API and rebuilds a snapshot of *public edge ownership*.

| Scope question | Default behavior today |
|---|---|
| Where does the Deployment run? | ServiceRadar **release namespace** (e.g. `demo`, `serviceradar`) |
| What API can it list? | **Cluster-wide** `ClusterRole`: Services, EndpointSlices, Nodes (Ready), Gateway API objects in **all namespaces** (unless narrowed) |
| What is stored? | Endpoints that look **public/edge** (LoadBalancer ingress, ExternalIP, Gateway listeners), plus a separate Node readiness catalog when enabled; not every ClusterIP |
| Does it see pod traffic? | No. Backend `endpoint_targets` are **control-plane** EndpointSlice refs (pod IP:port, name, node)—not flow bytes |
| Multi-tenant isolation | Rows are tagged with `cluster_id`. Namespace allow-lists are optional (see below) |

**Demo reality check:** with inventory enabled and no namespace filter, the
collector sees public edges across the whole management cluster (platform
namespaces such as `envoy-gateway-system`, `harbor`, customer-ish namespaces,
etc.). That is correct for *our* shared demo cluster; it is **not** the right
default for every customer. Treat `clusterId` + optional `namespaces` as part of
the security design review with the customer platform team.

## Customer deployment (outside our demo)

Today the polished path is **co-located**: install ServiceRadar *into* the
customer’s Kubernetes cluster (or a dedicated observability namespace in that
cluster) and enable inventory there. The collector then publishes into that
cluster’s ServiceRadar NATS → core. That is the supported production shape.

```text
Customer cluster (or “workload cluster”)
┌─────────────────────────────────────────────────────────────┐
│  kube-apiserver  ◄── list/watch (read-only ClusterRole)     │
│         │                                                   │
│  serviceradar-k8s-inventory   (release ns, e.g. serviceradar)│
│         │  NATS mTLS                                        │
│  serviceradar-nats  →  core EventWriter                     │
│         │                                                   │
│  platform.public_endpoints_current  + attributed_flows join │
└─────────────────────────────────────────────────────────────┘
```

### Decision checklist (hand this to the customer)

1. **Which cluster is the source of truth for public VIPs?**  
   Only clusters that terminate LoadBalancer / Gateway traffic need inventory.
2. **Is ServiceRadar installed in that cluster?**  
   If yes → enable `k8sInventory` in the chart (below).  
   If no → inventory must still run *in that cluster* (it needs the apiserver);
   remote publish into a central ServiceRadar is a **planned multi-cluster**
   pattern, not the default Helm path yet (see [Remote / multi-cluster](#remote--multi-cluster-patterns)).
3. **Full cluster vs selected namespaces?**  
   Default: all namespaces (ClusterRole). Restrict with `k8sInventory.namespaces`
   when the customer only wants edge namespaces (e.g. `ingress-nginx`,
   `envoy-gateway-system`, `prod-apps`).
4. **Stable `clusterId`**  
   Required when enabled. Use a durable ID (`prod-us-east-1`, `acme-eks-prod`),
   not a random string. Multi-cluster inventory rows are disambiguated by this
   field in SRQL (`cluster_id:…`).
5. **Gateway API?**  
   Keep `gatewayAPI.enabled: true` if the cluster uses Gateway API; disable if
   only classic Service LoadBalancers matter (smaller RBAC surface).

### Co-located install (supported)

```yaml
# Customer values overlay — ServiceRadar chart in the customer cluster
k8sInventory:
  enabled: true
  clusterId: acme-prod-eks          # durable; appears in SRQL / UI
  publishMode: nats
  # Optional: limit inventory to edge / app namespaces (empty = all)
  # namespaces:
  #   - envoy-gateway-system
  #   - ingress-nginx
  #   - production
  gatewayAPI:
    enabled: true
  envoyProxyCRD:
    enabled: false                  # set true only if using Envoy Gateway CRDs
```

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  --namespace serviceradar --create-namespace \
  -f values-customer.yaml \
  --set k8sInventory.enabled=true \
  --set k8sInventory.clusterId=acme-prod-eks
```

Also required:

| Dependency | Why |
|---|---|
| Image `serviceradar-k8s-inventory` | Same tag/digest family as the rest of the release |
| Runtime mTLS certs (`k8s-inventory.pem` / key) | NATS client identity; chart cert generator includes them |
| NATS ACL for `CN=serviceradar-k8s-inventory` → `inventory.k8s.>` | Publish path |
| Core with EventWriter `K8S_INVENTORY` stream + migration | Persistence into `public_endpoints_current` |

### Namespace scoping

| Config | API visibility | When to use |
|---|---|---|
| `namespaces: []` (default) | All namespaces via ClusterRole | Single-tenant platform / full IR coverage |
| `namespaces: [a, b, …]` | Only those namespaces (env `K8S_INVENTORY_NAMESPACES`) | Customer wants edge-only or app-only inventory |

Notes:

- Public LoadBalancers often live in an **ingress / gateway** namespace while
  routes and backends live in **app** namespaces. Scoping too tightly (e.g.
  only `production`) can hide the LB Service that owns the VIP.
- Prefer: include every namespace that can own a public Service **or** a
  Gateway route **or** backend EndpointSlices you care about.
- RBAC today is still a **ClusterRole** even when the collector filters
  namespaces in software. A future hardening option is Role/RoleBinding per
  namespace only; until then, document the ClusterRole in the customer change
  request.

### What customers should *not* expect

- **Not** “install this one binary outside ServiceRadar and get full product UI.”  
  Inventory is a **sensor** that feeds ServiceRadar core. Without NATS → core →
  SRQL/web-ng, you only have the collector’s `/snapshot` JSON.
- **Not** packet-level visibility of “cluster-wide traffic.”  
  NetFlow/sFlow still come from routers/exporters; process attribution still
  comes from **netprobe on nodes**. Inventory only answers *who owns the VIP*.
- **Not** host-agent kube credentials.  
  Workers never get this ClusterRole.

### Remote / multi-cluster patterns

| Pattern | Status | Notes |
|---|---|---|
| **A. Co-located** — full ServiceRadar + inventory in the workload cluster | **Supported today** | Direct NATS publish; use chart values above |
| **B. Sensors only** — inventory + **cluster agent** → agent-gateway → central/SaaS | **Designed (in progress)** | Intended SaaS / multi-cluster path; no NATS/core in the customer cluster. See OpenSpec `add-remote-k8s-inventory-via-agent` |
| **C. Direct remote NATS** — inventory publishes to central JetStream | **Not preferred** | Exposes NATS / leaf topology; weaker alignment with edge onboarding |
| **D. Workstation snapshot** — `k8s-inventory snapshot` with admin kubeconfig | Lab / break-glass | No continuous publish |

#### Pattern B (target for SaaS and 50-cluster fleets)

Customers should **not** need ServiceRadar running everywhere. The product shape is
the same as other edge sensors:

```text
Customer cluster (no full ServiceRadar)
┌──────────────────────────────────────────────┐
│  k8s-inventory  (ClusterRole, watches API)   │
│         │ spool (local volume)                 │
│  serviceradar-agent  (Deployment, replicas=1)│
│         │ outbound mTLS gRPC                   │
└─────────┼──────────────────────────────────────┘
          ▼
   agent-gateway  (central or serviceradar.cloud)
          │ JetStream inventory.k8s.public_endpoints
          ▼
   core EventWriter → public_endpoints_current
          │
          └─► SRQL / Attributed Flows (cluster_id disambiguates)
```

| Component in customer cluster | Role |
|---|---|
| `serviceradar-k8s-inventory` | Only process with kube API inventory RBAC |
| `serviceradar-agent` (cluster agent) | Enrolled edge identity; reads spool; pushes to gateway |
| Host DaemonSet agents (optional) | Netprobe / workload-identity on nodes—**no** inventory ClusterRole |

Do **not** reuse one `clusterId` across clusters. Host DaemonSet agents never
receive the inventory ServiceAccount token.

##### Helm: sensors-only chart

Use **`helm/serviceradar-k8s-edge`** — not the full `helm/serviceradar` chart.

```bash
# Enrollment secret from edge package (once)
kubectl create namespace serviceradar-edge
kubectl -n serviceradar-edge create secret generic sr-edge-agent-mtls \
  --from-file=root.pem=./root.pem \
  --from-file=agent.pem=./agent.pem \
  --from-file=agent-key.pem=./agent-key.pem

helm upgrade --install acme-edge ./helm/serviceradar-k8s-edge \
  -n serviceradar-edge --create-namespace \
  -f values-example.yaml
# values-example.yaml sets clusterId, agent.gatewayAddress, existingTlsSecret
```

| Chart | Installs |
|---|---|
| `helm/serviceradar` | Full platform (+ optional inventory over NATS) |
| `helm/serviceradar-k8s-edge` | **Agent + inventory only** → remote agent-gateway |

See `helm/serviceradar-k8s-edge/README.md`. Data plane wiring
(`PUBLISH_MODE=agent_spool` → agent → gateway) is tracked in OpenSpec
`add-remote-k8s-inventory-via-agent`.

### Platform team FAQ

**Q: Does this give ServiceRadar root on our cluster?**  
A: No. Read-only list/watch on Services, EndpointSlices, and (optionally)
Gateway API types. No secrets, no pods/exec, no nodes/proxy, no write verbs.

**Q: Can we run it in a locked-down namespace only?**  
A: The Deployment runs in the ServiceRadar release namespace. API scope can be
limited with `namespaces: […]`, but public VIP ownership often requires seeing
the ingress/gateway namespace as well.

**Q: We only care about one public VIP.**  
A: Still enable the collector (cheap continuous snapshot). Query
`in:public_endpoints ip:…` or Attributed Flows for that VIP; inventory cost is
API watches, not traffic volume.

**Q: Our ServiceRadar is SaaS / another VPC.**  
A: Prefer co-located core for that cluster, or a deliberate multi-cluster
publish design (pattern B). Do not open the customer apiserver to ServiceRadar
Cloud without a written trust model.

## Architecture

```text
kube-apiserver
    │  get/list/watch (read-only ClusterRole; optional namespace filter)
    ▼
serviceradar-k8s-inventory  (Deployment + ServiceAccount in release ns)
    │  snapshot JSON  (cluster_id stamped)
    ▼
NATS JetStream  subject inventory.k8s.public_endpoints
    │  (stream k8s_inventory)
    ▼
core EventWriter  →  platform.public_endpoints_current
    │
    ├─► SRQL / web-ng  in:public_endpoints
    │                  UI: /inventory/public-endpoints
    └─► FlowAttribution.Correlation  (VIP → backend → process)
                       attribution.public_endpoint on attributed_flows
```

You can:

1. Run **`k8s-inventory snapshot`** from a workstation (uses your kubeconfig).
2. Run the **in-cluster collector** (uses the Helm ServiceAccount) and publish
   to NATS JetStream (`inventory.k8s.public_endpoints`).
3. Query current ownership via SRQL (core EventWriter + migration):

   ```text
   in:public_endpoints ip:198.51.100.10 port:22
   in:public_endpoints cluster_id:acme-prod-eks exposure_class:Gateway
   ```

   Rows land in `platform.public_endpoints_current` (soft-delete on reassignment).

4. Open the dedicated list page in web-ng:

   ```text
   /inventory/public-endpoints
   /inventory/public-endpoints?q=in:public_endpoints+ip:198.51.100.10
   ```

   Submitting `in:public_endpoints …` from the global SRQL bar on other pages
   navigates here (catalog route is `/inventory/public-endpoints`).

5. Prefer **Attributed Flows** for IR when netprobe is enabled—owner is joined
   automatically (`service_name:…`, `exposure_class:…`).

## Helm: ServiceAccount and RBAC

**You do not create the ServiceAccount by hand for a normal install.**  
When `k8sInventory.enabled: true`, the chart template
`helm/serviceradar/templates/k8s-inventory.yaml` creates:

| Resource | Name |
|---|---|
| ServiceAccount | `serviceradar-k8s-inventory` (release namespace) |
| ClusterRole | `serviceradar-k8s-inventory` |
| ClusterRoleBinding | SA → ClusterRole |
| Deployment | `serviceradar-k8s-inventory` |
| Service | metrics on port `9109` |

### ClusterRole (least privilege)

Read-only verbs only: `get`, `list`, `watch` on:

- `services` (core)
- `nodes` (core), when `k8sInventory.nodes.enabled` is true (the default)
- `endpointslices` (`discovery.k8s.io`)
- Gateway API resources when `k8sInventory.gatewayAPI.enabled: true`
  (`gateways`, `httproutes`, `grpcroutes`, `tcproutes`, `udproutes`, `tlsroutes`)
- Optional `envoyproxies` (`gateway.envoyproxy.io`) when
  `k8sInventory.envoyProxyCRD.enabled: true`

**Not granted:** secrets, pods/exec, nodes/proxy, create/update/delete on
cluster objects.

Node snapshots publish on `inventory.k8s.nodes`. EventWriter upserts
`platform.k8s_nodes_current`. For readiness behavior and notification setup,
see [Kubernetes node NotReady](./notifications.md#kubernetes-node-notready).

The standalone collector defaults `K8S_INVENTORY_NODES` to `false`; the main
Helm chart sets it from `k8sInventory.nodes.enabled` (default `true`) when
inventory is enabled. Node watching needs cluster-wide Nodes RBAC and is
unaffected by namespace allow-lists. Enabling it with `PUBLISH_MODE=agent_spool`
is rejected at startup because that sink holds only the endpoint snapshot.
Node snapshots use the fixed subject above, independent of
`K8S_INVENTORY_SUBJECT`.

### Values

```yaml
# values.yaml — off by default
k8sInventory:
  enabled: false
  replicaCount: 1
  clusterId: ""                 # required when enabled; durable per cluster
  publishMode: nats             # nats | stdout | none
  namespaces: []                # empty = all namespaces; else allow-list
  gatewayAPI:
    enabled: true
  envoyProxyCRD:
    enabled: false
  nats:
    hostPort: "tls://serviceradar-nats:4222"
    subject: "inventory.k8s.public_endpoints"
    stream: "k8s_inventory"
  metrics:
    port: 9109
```

Demo overlay (`values-demo.yaml`) sets `enabled: true` and `clusterId: demo`
(no namespace filter—full management-cluster edges).

## Enable on a cluster

### Preferred: Helm / Argo CD (GitOps)

If ServiceRadar is managed by Argo CD (for example Application
`serviceradar-demo-prod`):

1. Land chart + values changes on the **Git revision Argo tracks**
   (`targetRevision` / release branch), not only on a local worktree.
2. Ensure the **image tag** Argo deploys actually contains
   `serviceradar-k8s-inventory`.
3. Let Argo **Sync** the Application (or wait for automated sync).

That path creates the ServiceAccount, RBAC, and Deployment together and keeps
desired state in Git.

### Manual Helm on an Argo-managed release — avoid

Do **not** run `helm upgrade` against the same release name/namespace Argo owns
(for demo: release `serviceradar`, namespace `demo`) unless you fully understand
the drift model.

| Setting (demo Application) | Effect |
|---|---|
| `automated.enabled: true` | Argo reconciles when its Git revision changes |
| `selfHeal: false` (when set) | Argo does **not** continuously overwrite live drift on a timer |
| `prune: false` (when set) | Argo does **not** delete extra resources unknown to Git |

Even with self-heal off, a later Argo sync from an **older Git revision** that
does not enable inventory can leave the app **OutOfSync**, and a sync with
prune enabled could remove resources. Fighting Argo with a second helm client
on the same release is a common source of “it disappeared after sync.”

**Safe lab options if you are not ready to move Argo’s `targetRevision`:**

1. **Workstation snapshot only** (no SA):  
   `k8s-inventory snapshot --cluster-id demo --ip <vip>` using your kubeconfig.
2. **Standalone manifests** (not part of the Argo app):  
   `helm template … > /tmp/k8s-inventory.yaml` and `kubectl apply -f …` with a
   clear label such as `app.kubernetes.io/managed-by=lab-manual`. Delete when
   done. Argo will not manage those objects unless you adopt them into the app.
3. **Pause the Application** (`argocd app suspend` / disable auto-sync),
   experiment, then resume and sync from Git.

### Fresh Helm install (not Argo)

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  --namespace demo \
  -f helm/serviceradar/values-demo.yaml \
  --set k8sInventory.enabled=true \
  --set k8sInventory.clusterId=demo \
  --set global.imageTag=<tag-that-includes-k8s-inventory>
```

## Incident response workflow

1. **Alert / flow:** external source → public `IP` or LB hostname + port
   (for example NetFlow `dst_ip=198.51.100.10 dst_port=22` from a geo-tagged peer).
2. **Ownership (cluster-plane inventory):**

   Preferred in the product UI / SRQL:

   ```text
   in:public_endpoints ip:198.51.100.10 port:22
   ```

   Open `/inventory/public-endpoints` or submit that query from the SRQL bar
   (it routes to the inventory page).

   CLI / lab alternatives:

   ```bash
   # Workstation with kubeconfig
   k8s-inventory snapshot --cluster-id demo --ip 198.51.100.10 --port 22

   # Live collector snapshot API
   kubectl -n demo port-forward svc/serviceradar-k8s-inventory 9109:9109
   curl -s localhost:9109/snapshot | jq '.endpoints[] | select(.ip=="198.51.100.10")'
   ```

3. **Interpret:**
   - `exposure_class: LoadBalancer` + Service name → edge proxy / LB Service
     (demo: Envoy Gateway LB in `envoy-gateway-system`, MetalLB pool)
   - `exposure_class: Gateway` + `route_kind` / `route_name` → Gateway API path
     (demo: `TCPRoute/git-ssh` → Service `git-ssh`)
   - `endpoint_targets` / correlation hints → post-DNAT pod IP:port
     (what netprobe attributes on the worker, e.g. `envoy` on `:10022`,
     `sshd` on `:2222`)

4. **Attributed flows (auto-joined):** with inventory and netprobe both live,
   core’s flow correlator expands public VIP:port → backend pod sockets and
   stamps process + owner onto `attributed_flow` rows. Prefer:

   ```text
   in:attributed_flows dst_ip:198.51.100.10 dst_port:22 time:last_24h
   in:attributed_flows service_name:git-ssh time:last_24h
   in:attributed_flows exposure_class:Gateway process:sshd time:last_24h
   ```

   Open **Observability → Attributed Flows**. Rows show process (e.g. `envoy`,
   `sshd`) and public endpoint owner (`Gateway: git-ssh`, route, namespace).
   The payload field is `attribution.public_endpoint`.

   Inventory (`in:public_endpoints`) remains the control-plane source of truth
   and drill-down surface; you should not need a second ad-hoc query for the
   common IR path once correlation has run (correlator interval is ~2 minutes).

## Build and test (Bazel)

Prefer Bazel (see `Bazel.md` / `BUILD.md`). From the repo root:

```bash
# Unit tests (no cluster)
bazel test //go/pkg/k8sinventory:k8sinventory_test

# Binary
bazel build //go/cmd/k8s-inventory:k8s-inventory

# OCI image (linux/amd64 — use remote from macOS)
bazel build -c opt --config=ci //docker/images:k8s_inventory_image_amd64

# Push (on macOS use scripts/push_all_images.sh or the crane/jq patch path
# documented in that script; plain `bazel run -c opt --config=ci //docker/images:k8s_inventory_image_amd64_push` fails on Darwin)
```

`MODULE.bazel` exposes `io_k8s_api` for typed core/discovery APIs. The image is
registered in `docker/images/image_inventory.bzl` as
`serviceradar-k8s-inventory`.

## Workstation CLI (no ServiceAccount)

Build from source (or use a released binary when available):

```bash
# go (dev) or bazel-built binary
go build -o k8s-inventory ./go/cmd/k8s-inventory
# or: bazel build //go/cmd/k8s-inventory:k8s-inventory

k8s-inventory snapshot --cluster-id demo --ip 198.51.100.10 --port 22
k8s-inventory snapshot --cluster-id demo --hints-only --ip 198.51.100.10
```

Long-running with stdout (validates watch/rebuild without NATS):

```bash
PUBLISH_MODE=stdout CLUSTER_ID=demo \
  K8S_INVENTORY_METRICS_ADDR=127.0.0.1:9109 \
  ./k8s-inventory run
```

This path uses **your user credentials**, not `serviceradar-k8s-inventory`.

## In-cluster health

```bash
kubectl -n <namespace> get deploy,sa,clusterrole | grep k8s-inventory
kubectl -n <namespace> logs deploy/serviceradar-k8s-inventory
kubectl -n <namespace> port-forward svc/serviceradar-k8s-inventory 9109:9109
curl -s localhost:9109/healthz
curl -s localhost:9109/readyz
curl -s localhost:9109/metrics
```

## Support tiers

Ownership is derived from the **Kubernetes API** (`Service.status`,
EndpointSlices, Gateway API). It does **not** require IPVS specifically.

| Environment | Tier |
|---|---|
| ServiceRadar demo (k3s + MetalLB + Envoy Gateway) | **Tested** |
| Other self-managed clusters (iptables/nft kube-proxy, same API objects) | Supported, untested in CI |
| EKS / GKE / AKS / Tanzu (often hostname-only LBs) | **Experimental** until validated; inventory stores hostname and optional IP |

## Related

- [NetFlow Ingest Guide](./netflow.md) — flow telemetry that surfaces public destinations  
- [Host Network Visibility](./netprobe.md) — process attribution on workers  
- [Workload Identity](./workload-identity.md) — pod/container metadata  
- [Kubernetes External Ingestion](./kubernetes-ingestion.md) — exposing collectors  
- Package notes: `go/pkg/k8sinventory/README.md`  
- OpenSpec: `openspec/changes/add-k8s-public-endpoint-inventory/`
