# Change: Remote Kubernetes public endpoint inventory via agent path

## Why

Public endpoint inventory today assumes **co-located ServiceRadar**: the
`serviceradar-k8s-inventory` Deployment publishes **directly to in-cluster NATS**
with mTLS certs from the full platform install. That only works when the
customer runs NATS + core + EventWriter in the same cluster (our demo, or a
full self-hosted footprint).

That model fails for the product cases we care about next:

1. **SaaS / serviceradar.cloud** — customers will not host ServiceRadar at all.
2. **Multi-cluster** — a platform team with dozens of EKS/GKE/AKS clusters
   should not install a full ServiceRadar stack in each one just to answer
   “who owns this LoadBalancer VIP?”
3. **Least-install edge** — observability into a cluster should mean installing
   **sensors**, not the whole control plane.

ServiceRadar already solves remote telemetry for hosts: **agent → agent-gateway
→ (NATS / core)**. Endpoint software inventory and workload-identity already use
the **local spool → agent push** pattern. Public endpoint inventory should ride
that same pipe so remote clusters only need:

- `serviceradar-k8s-inventory` (cluster-plane, kube API SA)
- `serviceradar-agent` (outbound mTLS to agent-gateway; **no** kube API token)

## What Changes

- **ADD publish mode / path:** inventory collector can deliver snapshots via the
  **agent status path** (not only direct NATS), so clusters without ServiceRadar
  NATS can still feed central/SaaS core.
- **ADD cluster-edge install shape:** documented + Helm (or thin chart) for
  “inventory + agent only” in a remote cluster: outbound-only to
  `agent-gateway`, durable `cluster_id`, optional namespace allow-list.
- **ADD agent integration:** agent reads inventory spool (or equivalent local
  handoff) and pushes on the existing authenticated gateway RPC
  (`StreamStatus` / reserved source discriminator), reusing gateway-attested
  tenant/agent identity.
- **ADD gateway → JetStream routing:** agent-gateway admits the payload and
  publishes onto the same family as today
  (`inventory.k8s.public_endpoints` / stream `k8s_inventory`) so **core
  EventWriter and SRQL stay unchanged**.
- **PRESERVE security split:** host/node agents still MUST NOT hold inventory
  ClusterRole credentials. Only the inventory Deployment talks to the apiserver.
- **PRESERVE co-located NATS path** for full in-cluster installs (demo, HA).

## Explicit non-goals (this change)

- Replacing NetFlow or netprobe (still separate planes).
- Giving every DaemonSet agent a kube API token.
- Requiring ERTS, CNPG, or web-ng in the customer cluster.
- Full multi-cluster product UI redesign (rows already key by `cluster_id`).
- Shipping SaaS onboarding UX end-to-end (can follow; this change is the data plane).

## Impact

- **Affected code:** `go/pkg/k8sinventory` (spool/publish modes),
  `go/cmd/k8s-inventory`, `go/pkg/agent` (spool ingest + status source),
  `serviceradar_agent_gateway` (route to NATS subject), Helm templates /
  optional remote chart, docs.
- **Unchanged:** core EventWriter processor, `public_endpoints_current`
  schema, SRQL entity, VIP→attributed-flow join (already cluster_id-aware).
- **Operators:** new supported install: “remote cluster sensors only.”
- **SaaS:** prerequisite for cloud customers to get K8s VIP ownership without
  hosting ServiceRadar.

## Depends on

- `add-k8s-public-endpoint-inventory` (collector, RBAC model, core ingest, SRQL)
  — largely landed; this change extends **transport topology**, not the ownership
  model.

## Risks

| Risk | Mitigation |
|---|---|
| Large snapshots blow gRPC status budgets | Chunk StreamStatus; content-hash skip; size limits + metrics |
| Spooled payload identity spoofing | Gateway mTLS agent identity; optional payload signature; never trust cluster_id from unauthenticated path |
| Confusion with per-node agents | Document “cluster agent” as Deployment (1 replica), not DaemonSet |
| Dual publish (NATS + agent) double-ingest | Exclusive publish mode per install; soft-delete generation still correct |
