# Change: Add Kubernetes public endpoint / VIP ownership inventory

## Why

Incident response against public LoadBalancer / Gateway VIPs still requires
manual gitops greps and `kubectl get svc -A`. Concrete example: inbound
connections from Colombia to `23.138.124.7:22` took multiple hops to identify as
the Forgejo Envoy Gateway (`forgejo-gateway` → TCPRoute `forgejo-ssh` → Forgejo
SSH), not a host shell.

ServiceRadar already has NetFlow + GeoIP, host process attribution (netprobe),
and node-local Workload Identity. None of those answer **"which Kubernetes
Service / Gateway owns this public IP:port?"** Process attribution also cannot
join edge NetFlow (`dst=VIP:22`) to pod sockets after kube-proxy/IPVS DNAT
(`local=podIP:10022`) without a separate control-plane map.

Forgejo issue: [#4849](https://code.carverauto.dev/carverauto/serviceradar/issues/4849).

## What Changes

- **ADD capability `k8s-public-endpoint-inventory`:** a dedicated in-cluster Go
  collector (`serviceradar-k8s-inventory`) that watches Kubernetes API objects
  with **least-privilege read-only RBAC** and publishes a current-state public
  endpoint catalog to core (NATS → ingest → `platform.public_endpoints_current`).
- **Security model (non-negotiable):** node agents, netprobe, and
  workload-identity **SHALL NOT** receive Kubernetes API credentials. Only the
  inventory Deployment (few replicas, own ServiceAccount) talks to the
  apiserver—same split as Datadog Cluster Agent / Dynatrace ActiveGate
  kubernetes-monitoring.
- **Go implementation:** new binary under `go/cmd/k8s-inventory` (client-go
  informers) + shared package under `go/pkg/k8sinventory` as needed.
- **Helm (optional):** chart values `k8sInventory.enabled` default **false**;
  when enabled, render Deployment, ServiceAccount, ClusterRole/Binding
  (or Role/RoleBinding when namespace-scoped), ConfigMap, SPIRE/mTLS hooks
  consistent with other collectors. Demo enables via `values-demo.yaml`.
- **SRQL:** `in:public_endpoints` for IR lookup by IP/port/protocol/namespace.
- **P1 (same change or immediately sequential tasks):** optional flow join so
  `ocsf_network_activity` rows can display endpoint owner for matching dest
  IP/port without kubectl.
- **DNAT / IPVS process correlation:** explicitly **out of P0**. Optional later
  track that reuses inventory VIP→backend maps **in core** (still no host-agent
  kube API). Marked experimental until multi-dataplane testing exists.

### Provider / dataplane coverage

Public **ownership inventory** is sourced from the Kubernetes API
(`Service.status.loadBalancer.ingress`, Service ports, EndpointSlices, Gateway
API addresses/listeners/routes). That path is **dataplane-agnostic**: it does
not depend on IPVS vs iptables vs nftables vs cloud controller internals.

| Environment | Ownership inventory (P0) | Notes |
|---|---|---|
| **k3s + MetalLB + IPVS (demo)** | **Supported / tested** | Primary validation target; VIP pins via MetalLB annotations + Gateway API |
| **kube-proxy iptables/nft (self-managed)** | Supported (same API path) | Untested in CI; expected equivalent for Service/EndpointSlice/Gateway |
| **EKS (NLB/ALB/CLB)** | Supported with caveats | `loadBalancer.ingress` may be **hostname** not IP; store hostname; IP resolve optional/experimental |
| **GKE** | Supported with caveats | Same hostname-vs-IP; Gateway API maturity varies by channel |
| **AKS** | Supported with caveats | Same as above |
| **Tanzu / vSphere Supervisor / others** | Experimental | Same API contracts where Gateway API / LoadBalancer Services exist; no dedicated test matrix |

Explicit labels in docs and Helm:

- `supportTier: tested` — demo k3s path  
- `supportTier: supported-untested` — other CNIs/kube-proxy modes using standard Service/Gateway API  
- `supportTier: experimental` — cloud LB hostname-only endpoints, multi-cluster, non-standard ingress controllers without Gateway API  

### Non-goals

- Granting kube API access to host agents or netprobe  
- Replacing NetworkPolicy / admission / ExternalDNS  
- SSH DPI or application log parsing  
- Using host `ipvsadm` / `kube-ipvs0` as primary ownership source of truth  
- Full multi-cloud E2E CI for every managed Kubernetes flavor in v1  

## Impact

- **Affected specs (new):** `k8s-public-endpoint-inventory`
- **Affected specs (delta):** `srql`, `edge-architecture` (security/deployment boundary), `container-image-builds` (new image)
- **Affected code:**
  - `go/cmd/k8s-inventory`, `go/pkg/k8sinventory` (new)
  - `helm/serviceradar/` templates + `values.yaml` + `values-demo.yaml`
  - `elixir/serviceradar_core` ingest + platform schema migration
  - `rust/srql` entity `public_endpoints`
  - docs under `docs/docs/` (IR runbook + security model)
- **Issue:** #4849
- **Depends on:** existing NATS/mTLS collector patterns; no dependency on netprobe health
- **Coordinates with:** optional later DNAT correlation; prefix-tags (#4641 family) remain CIDR-level and complementary
