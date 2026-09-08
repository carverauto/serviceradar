## Context

Operators investigating inbound traffic to public addresses in a MetalLB /
Gateway API edge farm currently reverse-engineer ownership by hand (gitops pin +
live Service/Gateway). ServiceRadar already sees *that* traffic (NetFlow + GeoIP)
and *which process* owns sockets on workers (netprobe), but not *which product
surface* a VIP is.

Security constraint from #4849: **do not** put Kubernetes API credentials on
host agents. Industry pattern (Datadog Cluster Agent, Dynatrace ActiveGate
kubernetes-monitoring) is a thin cluster-plane observer with narrow RBAC.

Implementation language: **Go** (`client-go` informers), consistent with other
ServiceRadar Go control-plane clients and easier Gateway API typed clients.

## Goals / Non-Goals

### Goals

- Continuous current-state inventory of public/edge endpoints discoverable from
  the Kubernetes API without kubectl.
- Least-privilege, single-purpose Go Deployment as the **only** kube API client
  for this feature.
- Optional Helm install; demo enables via `values-demo.yaml`.
- Works for **any** cluster that exposes LoadBalancer Services and/or Gateway
  API—independent of kube-proxy mode (IPVS/iptables/nft) or CNI.
- Clear support tiers: tested (demo k3s), supported-untested (other self-managed),
  experimental (cloud LB hostname edge cases, untested distros).
- SRQL lookup by IP / hostname / port for IR.

### Non-Goals

- Host-agent or netprobe Kubernetes API access.
- P0 DNAT-aware process↔flow join (separate experimental follow-on).
- Full managed-cloud E2E matrix (EKS/GKE/AKS/Tanzu) before merge.
- GitOps drift detection as primary SoT (optional P2).
- Replacing Ingress-only shops that lack LoadBalancer/Gateway (Ingress can be a
  later optional informer).

## Decisions

### D1 — Cluster inventory Deployment, not node agent

**Decision:** Ship `serviceradar-k8s-inventory` as a Deployment (default 1
replica; optional 2 for HA with leader election later). Own ServiceAccount.

**Why:** Mirrors Datadog/Dynatrace; minimizes blast radius; token revocation is
independent of fleet agents.

**Alternatives rejected:**

- Node agent informers → combines host privilege with cluster read; rejected.
- core-elx as kube client → enlarges core attack surface; harder to revoke;
  multi-replica watch storms unless leader-elected carefully. Core **consumes**
  events only.

### D2 — Go + client-go informers

**Decision:** Implement watcher in Go under `go/cmd/k8s-inventory`.

**Why:** First-class Kubernetes ecosystem, shared Gateway API Go APIs, matches
repo Go collector patterns. Rust kube client is viable but slower to land for
Gateway API CRDs.

### D3 — API sources for ownership (dataplane-agnostic)

**Decision:** Primary ownership comes from:

| Object | Fields used |
|---|---|
| `Service` (type LoadBalancer, ExternalIPs, or annotated public) | `status.loadBalancer.ingress[]` (ip **and/or** hostname), `spec.ports`, `spec.externalTrafficPolicy`, MetalLB / ExternalDNS annotations |
| `EndpointSlice` | backend addresses, ports, `targetRef` (pod name/namespace) |
| `Gateway` (Gateway API) | `status.addresses`, listeners (port/protocol/hostname) |
| `HTTPRoute` / `TCPRoute` / `UDPRoute` / `GRPCRoute` / `TLSRoute` | parentRefs, hostnames, backendRefs |
| Optional: `EnvoyProxy` (Envoy Gateway) | annotations carrying MetalLB IP pins when Service is controller-owned |

**Why this works without IPVS:** Cloud controllers and MetalLB both populate
`Service.status.loadBalancer` or Gateway `status.addresses`. kube-proxy mode only
affects **how packets are forwarded after** the VIP is accepted; it does not
change the ownership objects. Demo k3s IPVS is therefore a **transport detail**,
not a product dependency.

### D4 — Hostname vs IP (cloud LBs)

**Decision:**

- Store **both** `ip` (nullable) and `hostname` (nullable) on inventory rows.
- Lookup keys: exact IP match; exact hostname match; optional experimental
  async resolve of hostname→A/AAAA for flow join (feature flag, default off).
- EKS/GKE/AKS often present `hostname` only on classic ELB/NLB—document as
  **supported with caveats / experimental for flow IP join**.

### D5 — RBAC least privilege

**Decision:** ClusterRole (or namespaced Roles when `watchNamespaces` is set)
with **get/list/watch only** on:

```text
services
endpointslices.discovery.k8s.io
gateways, httproutes, grpcroutes, tcproutes, udproutes, tlsroutes
  (gateway.networking.k8s.io)
envoyproxies (gateway.envoyproxy.io)  # optional Helm flag
```

**Never:** secrets, pods/exec, nodes/proxy, create/update/delete/patch on cluster
objects (except optional leader-election lease on a dedicated coordination
resource if HA is enabled later).

EndpointSlice `targetRef` supplies pod names without listing all Pods.

### D6 — Publish path

**Decision:** Inventory process publishes normalized snapshots/deltas to NATS
JetStream subject family `inventory.k8s.public_endpoints` (final name in tasks)
with mTLS/SPIFFE identity matching other collectors. core-elx EventWriter /
dedicated processor upserts `platform.public_endpoints_current`.

Full resync on connect + watch events; soft-delete rows missing after resync
generation or explicit tombstone.

### D7 — Helm optional + demo on

**Decision:**

```yaml
# values.yaml
k8sInventory:
  enabled: false
  replicaCount: 1
  clusterId: ""          # required when enabled; demo sets "demo"
  watchNamespaces: []    # empty = all namespaces
  gatewayAPI:
    enabled: true
  envoyProxyCRD:
    enabled: true        # demo EG; disable if CRD absent
  supportTierDoc: true
```

`values-demo.yaml`:

```yaml
k8sInventory:
  enabled: true
  clusterId: demo
  envoyProxyCRD:
    enabled: true
```

Chart MUST tolerate missing Gateway API / EnvoyProxy CRDs (disable informers,
surface Ready=False condition or status metric—not CrashLoop).

### D8 — DNAT correlation is not P0

**Decision:** Document VIP→backend port maps in inventory so a **future** core
correlator can map NetFlow `VIP:22` → `podIP:10022` without host-agent API
access. Do not implement join in P0.

**Why:** Ownership IR is valuable alone; DNAT join needs careful ranking on
shared VIPs and multi-cloud testing.

### D9 — Support tier labels

**Decision:** Docs and `k8sInventory.support.note` in values describe tiers:

| Tier | Meaning |
|---|---|
| `tested` | Validated on ServiceRadar demo (k3s, MetalLB, Envoy Gateway, IPVS) |
| `supported-untested` | Built against public Kubernetes API contracts; not exercised in CI for that distro |
| `experimental` | Hostname-only cloud LBs, multi-cluster, non-Gateway Ingress-only, DNAT process join |

Customers on EKS/GKE/AKS/Tanzu SHOULD enable inventory for ownership lookup; they
MUST treat cloud-specific edge cases as experimental until we publish test
evidence.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Compromised inventory pod | Read-only RBAC; no secrets; NetworkPolicy; SPIFFE identity for publish |
| Compromised worker | No kube token on host agents |
| Missing Gateway CRDs | Feature flags; degrade gracefully |
| Cloud hostname-only VIP | Store hostname; optional resolve flag; doc experimental for IP flow join |
| Watch volume on large clusters | Informer caches; namespace allowlist; resync period tunable |
| Stale MetalLB reassignment | Soft-delete + resync generation |
| Fake inventory publisher | mTLS subject allowlist for inventory publisher identity |

## Migration Plan

1. Land OpenSpec + implementation behind `k8sInventory.enabled=false`.
2. Enable on demo via `values-demo.yaml`; verify `23.138.124.7` ownership.
3. Document IR runbook; no forced enable for tenants.
4. Rollback: set `enabled: false`; inventory table retains last snapshot until TTL
   or manual purge (define retention in tasks).

## Open Questions

- Exact NATS subject + protobuf package naming (align with existing inventory
  events if any).
- Whether `public_endpoints` joins `service_endpoints` AGE graph in the same
  change or a follow-up (prefer follow-up to keep P0 small).
- Leader election for replicaCount>1 in v1 vs single replica only.
- Optional Ingress informer in P1 vs strict LoadBalancer+Gateway only for P0.
