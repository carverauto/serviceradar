# Design: Remote k8s inventory via agent path

## Context

```text
TODAY (co-located only)
  k8s-inventory ──NATS mTLS──► JetStream ──► core EventWriter

DESIRED (remote / SaaS)
  k8s-inventory ──spool/local──► agent ──mTLS gRPC──► agent-gateway
        ──JetStream inventory.k8s.*──► core EventWriter
```

Customers with 50 clusters install only **inventory + agent** per cluster.
ServiceRadar (or SaaS) remains centralized.

## Goals

1. Zero ServiceRadar control-plane components in the remote cluster.
2. Outbound-only connectivity from customer network (agent → gateway).
3. Reuse existing identity, tenant isolation, and core ingest.
4. Keep kube API credentials off node-plane agents.

## Non-goals

- Direct inventory → SaaS NATS from customer clusters (bypasses agent identity
  and edge onboarding).
- Per-node inventory watches.

## Decision summary

| ID | Decision |
|---|---|
| D1 | **Transport:** agent status path (not direct remote NATS) for remote installs |
| D2 | **Handoff:** filesystem spool (mirror endpoint-inventory / workload-identity) |
| D3 | **Topology:** inventory Deployment + **cluster agent Deployment (replicas=1)** co-located in one namespace |
| D4 | **Source discriminator:** `k8s_public_endpoints` (or `inventory.k8s.public_endpoints`) on status payload |
| D5 | **Gateway:** map admitted status → JetStream `inventory.k8s.public_endpoints` |
| D6 | **Identity:** gateway-attested agent/partition/tenant; payload carries `cluster_id` as inventory metadata, validated against enrollment policy when available |
| D7 | **Publish modes mutually exclusive:** `nats` \| `agent_spool` \| `stdout` \| `none` |
| D8 | **Co-located demo keeps `nats`** |

## D1 — Why agent, not direct NATS from remote clusters

Direct JetStream from 50 customer clusters forces:

- exposing NATS (or leaf nodes) to the internet,
- distributing NATS mTLS material outside the platform install,
- weaker alignment with SaaS edge onboarding (packages, agent registry).

Agent-gateway is already the **public edge** of ServiceRadar: mTLS, enrollment,
tenant routing, payload admission. Inventory should be another **status source**
on that pipe—same as netprobe events, endpoint inventory, add-on telemetry.

## D2 — Spool handoff (local)

```text
/var/lib/serviceradar/k8s-inventory/spool/
  latest.json          # atomic replace on successful rebuild
  pending-upload.json  # optional: agent ack pattern if needed later
```

- `k8s-inventory` writes `latest.json` (same snapshot schema as NATS body).
- Agent watches mtime / generation; on change, pushes via `StreamStatus`
  (chunked—snapshots can be hundreds of KB).
- Shared emptyDir or hostPath **only on the cluster-agent pod** (not workers).

This matches `endpoint-inventory` and avoids coupling the Go inventory binary to
gRPC client code in v1.

**Alternative considered:** inventory embeds agent SDK and dials gateway itself.
Rejected for v1: duplicates enrollment, cert rotation, and config fetch already
owned by the agent.

## D3 — Pod topology in the remote cluster

```yaml
# Conceptual remote install (single namespace, e.g. serviceradar-edge)
Deployment/serviceradar-k8s-inventory   # SA + ClusterRole (or Role list)
Deployment/serviceradar-agent           # replicas: 1, "cluster agent"
  volumeMount: k8s-inventory-spool
```

- **Not** a DaemonSet for this sensor pair (DaemonSet agents stay host-plane).
- Optional later: same agent binary with a profile flag
  `role: cluster` vs `role: host`.
- NetworkPolicy: egress only to agent-gateway (and kube-apiserver for inventory).

## D4 / D5 — Status → JetStream

```text
Agent StreamStatus {
  source: "results" | dedicated inventory source
  service_type: "k8s_public_endpoints"
  message: <snapshot bytes or chunked JSON>
  metadata: { cluster_id, content_hash, generated_at, schema_version }
}
        │
        ▼
agent-gateway StatusProcessor
  admit (mTLS agent identity, size limits)
  publish JetStream subject inventory.k8s.public_endpoints
        │
        ▼
core EventWriter K8sPublicEndpoints  (unchanged)
```

Prefer **not** inventing a new core processor. Gateway is the adapter from
agent envelope → existing NATS contract.

## D6 — cluster_id and multi-tenant safety

- Inventory continues to stamp `cluster_id` in the snapshot (operator-configured).
- Gateway MUST attach authenticated `agent_id` / partition / tenant from mTLS.
- Core SHOULD store both: `cluster_id` (K8s identity) and agent provenance
  (who pushed). Soft-delete remains per cluster_id.
- Policy (follow-up): bind enrolled agent package → allowed `cluster_id`s so a
  stolen agent cannot claim another cluster’s VIP ownership.

## D7 — Publish modes

| Mode | Use |
|---|---|
| `nats` | Full ServiceRadar install in-cluster (demo) |
| `agent_spool` | Remote / SaaS sensors only |
| `stdout` / `none` | Lab |

Installing both `nats` and `agent_spool` on the same collector is unsupported
(double publish). Chart validates exclusive mode.

## Comparison to co-located NATS path

| | Co-located NATS | Remote agent path |
|---|---|---|
| Customer install size | Full SR chart | inventory + agent |
| Outbound | internal NATS | agent-gateway only |
| SaaS-ready | No | Yes |
| Identity | inventory NATS cert | agent mTLS enrollment |
| Core ingest | EventWriter | EventWriter (same) |

## Open questions (resolve in implementation tasks)

1. Exact status `service_type` / `source` strings and protobuf fields.
2. Whether chunking reuses existing StreamStatus framing or a dedicated
   multi-chunk inventory schema.
3. Helm packaging: extend main chart with `k8sInventory.publishMode=agent_spool`
   + companion agent values vs separate `helm/serviceradar-cluster-sensors` chart.
4. Enrollment UX for “cluster agent” packages in web-ng / SaaS.

## Implementation sketch (ordered)

1. Spool writer in `k8sinventory` for mode `agent_spool`.
2. Agent spool reader + StreamStatus emit (mirror endpoint inventory service).
3. Gateway route → JetStream subject.
4. Integration test: spool file → fake gateway → assert subject payload.
5. Remote install docs + values example for SaaS.
6. Optional: thin Helm chart for remote sensors only.
