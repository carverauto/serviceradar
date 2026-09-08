## Context
The current `demo` control plane is halfway to a clustered design:
- `core`, `web-ng`, and `agent-gateway` already expose headless services and libcluster DNS configuration.
- the platform architecture spec already says those services form an internal ERTS cluster in Kubernetes.
- `agent-gateway` already allows a configurable replica count in Helm.

But the deployed topology is still effectively singleton for every major control-plane workload, and some implementation details are not safe to scale without explicit design work:
- `core` is always deployed with `SERVICERADAR_CLUSTER_COORDINATOR=true`, so scaling replicas without a coordinator policy would create duplicate "leader" nodes.
- `core` still relies on a pod-local init-container migration path, which is not a sound ownership model for replicated startup.
- live agent and gateway state is tracked in ETS-backed processes such as `ServiceRadar.AgentTracker` and `ServiceRadar.GatewayTracker`, which means replica placement and restart behavior must be considered explicitly.
- `web-ng` and operator-facing pages already aggregate some live state via cross-node RPC, which is useful, but it is still a runtime contract that must be validated under replica loss and rolling updates.
- NATS is currently a single `Deployment` with one PVC, so there is no real broker or JetStream redundancy today.

## Goals / Non-Goals
- Goals:
  - Run `core`, `web-ng`, and `agent-gateway` as a healthy multi-replica cluster in `demo`.
  - Preserve a single logical owner for coordinator and scheduler duties.
  - Keep live operator-visible state correct across replicas and restarts.
  - Replace singleton demo NATS with a real clustered topology.
  - Scale stateless observability ingress services in `demo` where shared durable state is not required.
  - Make the demo rollout exercise the same distributed assumptions we claim in architecture docs.
- Non-Goals:
  - Introduce cross-region or multi-cluster federation.
  - Solve generic autoscaling or horizontal pod autoscaler policy in this change.
  - Redesign every registry/tracker abstraction unless it is required for correct clustered behavior.
  - Treat singleton storage or consumer ownership as solved for `datasvc`, `zen`, or `db-event-writer` without explicit redesign.

## Decisions

### Decision: Treat `core` as a replicated service with singleton responsibilities
Multiple `core` replicas are desirable for availability, but coordinator duties cannot simply run on every pod. The target design must distinguish between:
- `core` replicas that are healthy members of the ERTS cluster
- the single active coordinator responsible for cluster-authoritative work such as scheduling or other singleton duties

Consequences:
- Helm and runtime config cannot hardcode every `core` pod as the coordinator.
- We need an explicit leader/singleton policy, not an accidental "first pod wins" behavior.

### Decision: Replica-safe live state is part of the acceptance criteria
The current platform already uses node-local ETS trackers and cross-node RPC to render live gateway and agent state. That may be sufficient, but only if the contract is made explicit and survives:
- requests landing on any `web-ng` pod
- agents connected to any `agent-gateway` pod
- rolling restarts and node loss

Consequences:
- This change is not just about changing `replicas`.
- The proposal must include validation of `/settings/cluster` and other live views against distributed placement.

### Decision: Runtime cert layout upgrades must preserve the existing trust root
`demo` control-plane rollouts can regenerate runtime server certificates to pick up new SANs or component layouts, but externally onboarded agents keep their installed trust root and client certificate material until they are explicitly reprovisioned.

Consequences:
- A layout-version bump must not silently rotate `root.pem` or other long-lived CA material.
- Runtime cert refreshes should regenerate leaf certificates by default while preserving the existing root and CNPG CAs unless rotation is explicitly requested.
- HA rollout validation must include external-agent reconnect behavior after runtime-cert hook execution.

### Decision: NATS clustering is a topology change, not a replica count change
The current NATS deployment is a singleton `Deployment` with one PVC. A multi-node NATS topology requires:
- clustered peer discovery
- stable peer identity
- per-node durable storage
- a client-facing service model that tolerates peer loss and rolling restarts

Consequences:
- NATS should move to a clustered contract such as a `StatefulSet` plus headless service, not a replicated singleton deployment.
- JetStream durability and quorum semantics must be defined explicitly.

### Decision: Stateless ingest services can scale before singleton consumers do
The next HA slice includes observability ingest services that only receive traffic and publish into shared NATS streams. Those services can scale independently as long as they do not depend on shared node-local state or singleton durable-consumer ownership.

Consequences:
- `trapd`, `log-collector`, `log-collector-tcp`, and `flow-collector` can use standard multi-replica `Deployment` semantics in `demo`.
- JetStream-backed workers such as `zen` and `db-event-writer` can scale by sharing one durable pull consumer across replicas instead of switching to push queue subscriptions.
- Replica-safe shared pull consumers still require non-consumer runtime work to be stateless: pod-local scratch storage, no singleton migration work, and startup that tolerates concurrent durable creation.
- `datasvc` can scale in Kubernetes when its file-backed resolver paths remain unset and its `/var/lib/serviceradar` mount is treated as pod-local scratch instead of authoritative storage.
- `bmp-collector` can scale as a per-connection ingress tier when each replica uses pod-local curation state and publishes normalized updates into shared JetStream subjects.
- Demo-only storage for safe ingest replicas may use pod-local scratch (`emptyDir`) instead of a shared single PVC when the service does not persist authoritative state there.

### Decision: Migration ownership must be serialized outside normal multi-replica startup
Per-pod migration init containers are acceptable for a singleton deployment, but they are the wrong contract for a replicated `core` rollout.

Consequences:
- This work must define a single migration owner or dedicated migration job.
- `web-ng` startup gates should continue to wait for schema readiness, but schema mutation itself should not be owned by every `core` pod.

## Risks / Trade-offs
- A poorly defined `core` leader contract will produce duplicate schedulers or split-brain coordinator behavior.
- Node-local tracker state may continue to be a hidden source of inconsistency if we do not make authoritative live-state rules explicit.
- Clustered NATS increases operational complexity in exchange for eliminating a major singleton broker failure mode.
- Moving migrations out of per-pod init paths may require chart and release-flow changes that affect more than `demo`.
- UDP/TCP ingest services still need runtime validation under external load balancers, especially when `externalTrafficPolicy: Local` is used.

## Migration Plan
1. Document the current singleton assumptions and define the target multi-replica topology.
2. Introduce replica-safe control-plane semantics for `core`, `web-ng`, and `agent-gateway`.
3. Move `core` migrations to a serialized ownership model.
4. Convert demo NATS to a clustered topology with durable peer storage.
5. Scale stateless observability ingest services where pod-local scratch storage is sufficient.
6. Validate rolling restarts, single-pod loss, and operator workflows before declaring demo HA-ready.

## Open Questions
- Should `core` use explicit leader election, or should one replica be assigned coordinator responsibility via deployment topology and readiness contracts?
- Is the current RPC aggregation over node-local ETS trackers sufficient, or do some live state paths need a more authoritative cluster-wide registry?
- Do agent connections require service affinity or any gateway-side coordination changes when the gateway pool scales beyond one replica in `demo`?
- What NATS JetStream quorum and storage layout is acceptable for `demo` versus production?
- Should any future JetStream worker use push `DeliverGroup` consumers, or is the shared durable pull-consumer pattern sufficient for all current ServiceRadar workloads?
