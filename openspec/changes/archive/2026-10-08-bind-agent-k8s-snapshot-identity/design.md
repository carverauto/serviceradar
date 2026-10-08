## Context

Remote Kubernetes inventory travels from the inventory collector through a cluster-scoped ServiceRadar agent and agent-gateway to `inventory.k8s.public_endpoints`. Agent-gateway derives `agent_id` and partition from the authenticated connection and adds them as NATS headers, but it republishes the JSON body unchanged. EventWriter currently ignores that authenticated provenance and uses the body `cluster_id` for row keys and cluster-wide soft deletion.

The cluster ID must remain operator-configurable and distinct from the ServiceRadar agent ID. A cluster may retain its identity while an agent is replaced, and the two values already serve different product purposes. Equating them would break the existing remote inventory contract.

## Goals / Non-Goals

### Goals

- Authorize every agent-forwarded Kubernetes snapshot against control-plane state.
- Prevent an enrolled agent from writing or deleting inventory owned by another cluster.
- Retain stable, operator-defined cluster IDs across agent replacement.
- Record enough provenance to explain which authenticated agent caused each accepted snapshot.
- Fail closed without deriving authorization from existing inventory rows or agent-supplied metadata.

### Non-Goals

- Redesign cluster IDs or replace them with agent IDs.
- Change the direct, in-cluster NATS publisher contract in this change.
- Treat NATS headers as proof for publishers that do not traverse agent-gateway.
- Add general multitenancy or tenant bypass modes.
- Repair unrelated NATS credential breadth findings.

## Decisions

### Store an explicit cluster ownership binding

The control plane will own a binding with these authoritative fields:

- `cluster_id`: the durable operator-configured Kubernetes identity; globally unique because current inventory keys and reconciliation are global by cluster ID
- `agent_id`: the enrolled ServiceRadar agent allowed to publish the cluster
- `partition_id`: the partition expected on the authenticated gateway session
- audit timestamps and the actor responsible for changes

The binding is an authorization record, not discovered inventory. Agent registration, heartbeat metadata, snapshot bodies, and existing endpoint rows cannot create or alter it. An administrator may transfer a cluster to a replacement agent through an explicit update that remains auditable.

An explicit resource is preferred over embedding an allow-list in generic agent metadata. It provides a unique owner for each cluster, restrictive database constraints, guarded deletion, and a clear management surface.

### Enforce at the state-changing consumer

Agent-gateway will continue to stamp the authenticated agent and partition. EventWriter will classify messages carrying the gateway's agent-path marker as agent-forwarded and require all of the following before parsing rows or starting a database transaction:

1. non-empty authenticated agent and partition provenance is present,
2. an active binding exists for the body `cluster_id`, and
3. the binding's agent and partition exactly match the authenticated provenance.

The authorized body `cluster_id` is then the sole effective cluster identity for every endpoint row. A nested per-endpoint `cluster_id` that is present and differs from the authorized body `cluster_id` rejects the snapshot before parsing rows or starting the database transaction, and row-key construction must not honor a nested override.

Failure drops or negatively acknowledges the snapshot according to the existing poison-message policy, emits a bounded security event/metric, and performs no upsert or soft delete. The check occurs again in the same database transaction that applies the snapshot so a concurrent ownership transfer cannot authorize a stale writer.

Checking only in agent-gateway would leave other consumers and replay paths dependent on a remote policy lookup. The state-changing consumer has the database transaction and remains the final authorization boundary.

### Preserve direct publisher compatibility explicitly

The existing in-cluster inventory component publishes directly to NATS and does not carry gateway-attested agent provenance. EventWriter will preserve that path as a distinct trusted publisher mode. It must not silently treat a malformed agent-path message as direct: the presence of any agent-path marker requires the complete authenticated provenance and binding check.

This decision assumes NATS subject permissions continue to distinguish platform publishers from enrolled remote agents, which have no direct NATS credentials in the supported topology. Narrowing platform NATS credentials is tracked separately.

### Persist accepted provenance

Accepted agent-path snapshots will persist the authenticated `agent_id` and `partition_id` in a cluster snapshot/audit record. Body fields with the same names remain forensic claims only and cannot override authenticated values. Current endpoint rows may retain their existing query shape; provenance belongs on the snapshot ownership record unless implementation review shows a row-level field is required for an existing query.

## Risks / Trade-offs

- Existing remote inventory stops updating until bindings are configured. This is the intended fail-closed migration behavior; documentation and validation errors must make the cause visible.
- A mistaken ownership transfer can pause the old agent or authorize the wrong enrolled agent. The management action must show the current owner, require an explicit replacement, and write audit history.
- Direct NATS publishers remain outside the agent binding. Their authorization depends on NATS service credentials and is covered by the separate JetStream-access workstream.
- Per-snapshot binding reads add database work. EventWriter may cache positive bindings only if invalidation is immediate on transfer; the initial implementation should prefer correctness and measure before caching.

## Migration Plan

1. Add the binding and provenance schema plus an administrator-only management surface.
2. Document how to create a binding from the operator's intended cluster and enrolled agent configuration.
3. Deploy enforcement in fail-closed mode for agent-forwarded snapshots. Do not auto-populate from current inventory, payloads, or agent metadata.
4. Verify an authorized synthetic snapshot updates only its bound cluster, then verify mismatched and unbound snapshots leave both existing and absent-row state unchanged.
5. Roll back application code if necessary while retaining the additive schema. Removing enforcement is a security rollback and must be explicit.

## Open Questions

- Whether the existing administrative agent detail page or a dedicated Kubernetes inventory settings page is the clearest management surface. The authorization and uniqueness rules do not depend on that UI choice.
