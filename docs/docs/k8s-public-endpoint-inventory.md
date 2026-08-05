---
sidebar_position: 10
title: Kubernetes Public Endpoint Inventory
---

# Kubernetes Public Endpoint Inventory

Public endpoint inventory answers **who owns this public IP or hostname:port?**
in a Kubernetes cluster—without running ad-hoc `kubectl get svc -A` during an
incident.

Typical IR question:

> We see NetFlow from Colombia to `23.138.124.7:22`. Is that a host shell,
> Forgejo git-SSH, or something else?

With inventory enabled, the collector maps that VIP to the Forgejo Envoy
Gateway LoadBalancer, the `ssh` Gateway listener / TCPRoute, and backend
pod sockets (for later process attribution joins).

Use this guide with [NetFlow](./netflow.md), [Host Network Visibility
(netprobe)](./netprobe.md), [Workload Identity](./workload-identity.md), and
[Helm configuration](./helm-configuration.md).

## What it is (and is not)

| It is | It is not |
|---|---|
| A **cluster-plane** inventory of LoadBalancer / ExternalIP / Gateway API edges | A host-agent feature |
| Ownership: Service, Gateway, route, backend EndpointSlice targets | Full SSH content inspection |
| Correlation **hints** (`VIP:port` → `podIP:targetPort`) for DNAT | Automatic NetFlow→process join (still a separate follow-on) |
| Optional Helm component (`k8sInventory.enabled`) | Enabled by default |

**Security model:** only the in-cluster `serviceradar-k8s-inventory` Deployment
holds Kubernetes API credentials. Host agents, netprobe, and workload-identity
**do not** get kube API access for this feature (same split as Datadog Cluster
Agent / Dynatrace ActiveGate-style designs).

## Architecture

```text
kube-apiserver
    │  get/list/watch (read-only ClusterRole)
    ▼
serviceradar-k8s-inventory  (Deployment + ServiceAccount)
    │  snapshot JSON
    ▼
NATS JetStream  subject inventory.k8s.public_endpoints
    │
    ▼  (future) core ingest → public_endpoints_current → SRQL
```

Today you can:

1. Run **`k8s-inventory snapshot`** from a workstation (uses your kubeconfig).
2. Run the **in-cluster collector** (uses the Helm ServiceAccount) and publish
   to NATS JetStream (`inventory.k8s.public_endpoints`).
3. Query current ownership via SRQL once core has migrated and is running a
   build that includes the EventWriter processor:

   ```text
   in:public_endpoints ip:23.138.124.7 port:22
   in:public_endpoints cluster_id:demo exposure_class:Gateway
   ```

   Rows land in `platform.public_endpoints_current` (soft-delete on reassignment).

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
- `endpointslices` (`discovery.k8s.io`)
- Gateway API resources when `k8sInventory.gatewayAPI.enabled: true`
  (`gateways`, `httproutes`, `grpcroutes`, `tcproutes`, `udproutes`, `tlsroutes`)
- Optional `envoyproxies` (`gateway.envoyproxy.io`) when
  `k8sInventory.envoyProxyCRD.enabled: true`

**Not granted:** secrets, pods/exec, nodes/proxy, create/update/delete on
cluster objects.

### Values

```yaml
# values.yaml — off by default
k8sInventory:
  enabled: false
  replicaCount: 1
  clusterId: ""                 # required when enabled; demo uses "demo"
  publishMode: nats             # nats | stdout | none
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

Demo overlay (`values-demo.yaml`) sets `enabled: true` and `clusterId: demo`.

Also required for a healthy in-cluster run:

- Image: `serviceradar-k8s-inventory` (tag from `image.tags.k8sInventory` /
  `global.imageTag`)
- Runtime mTLS certs: `k8s-inventory.pem` / `k8s-inventory-key.pem` in the
  chart runtime cert secret (cert generator includes them)
- NATS ACL for user `CN=serviceradar-k8s-inventory` publishing `inventory.k8s.>`
  (chart NATS config includes this when updated)

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

1. **Alert / flow:** external source → public `IP` or LB hostname + port.
2. **Ownership (today):**
   ```bash
   # From a machine with cluster API access (kubeconfig)
   k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22
   ```
   Or, once the Deployment is up:
   ```bash
   kubectl -n demo port-forward svc/serviceradar-k8s-inventory 9109:9109
   curl -s localhost:9109/snapshot | jq '.endpoints[] | select(.ip=="23.138.124.7")'
   ```
3. **Interpret:**
   - `exposure_class: LoadBalancer` + Service name → edge proxy / LB Service
   - `exposure_class: Gateway` + `route_kind` / `route_name` → Gateway API path
   - `endpoint_targets` / correlation_hints → post-DNAT pod IP:port (what
     netprobe may attribute, e.g. `envoy` on `:10022`)
4. **Process attribution (separate):** enable netprobe on the worker that hosts
   the backend pod; join is not automatic until VIP/DNAT correlation is wired
   in core.

## Build and test (Bazel)

Prefer Bazel (see `Bazel.md` / `BUILD.md`). From the repo root:

```bash
# Unit tests (no cluster)
bazel test //go/pkg/k8sinventory:k8sinventory_test

# Binary
bazel build //go/cmd/k8s-inventory:k8s-inventory

# OCI image (linux/amd64 — use remote from macOS)
bazel build //docker/images:k8s_inventory_image_amd64 --config=remote

# Push (on macOS use scripts/push_all_images.sh or the crane/jq patch path
# documented in that script; plain `bazel run //docker/images:k8s_inventory_image_amd64_push --config=remote` fails on Darwin)
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

k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22
k8s-inventory snapshot --cluster-id demo --hints-only --ip 23.138.124.7
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
- Issue tracking: forgejo `#4849`
