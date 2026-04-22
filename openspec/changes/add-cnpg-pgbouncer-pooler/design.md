## Context
ServiceRadar Kubernetes installs use CNPG as the primary PostgreSQL/Timescale database. Application services currently connect directly to the CNPG RW service and each service maintains its own runtime pool. That model is simple, but it lets aggregate service pool sizes exceed the number of Postgres backends the cluster can safely run. Under pressure, this shows up as checkout timeouts, slow LiveView loads, Oban notifier timeouts, and command/status persistence delays.

CNPG supports a first-class `Pooler` CRD backed by PgBouncer. Using that resource is preferable to a hand-rolled PgBouncer Deployment because CNPG owns cluster discovery, generated services, credentials integration, and lifecycle conventions.

## Goals
- Add a supported PgBouncer path for Kubernetes/Helm deployments.
- Enable the pooler in the `demo` namespace through Helm values.
- Reduce backend connection churn and cap database backend usage without disabling ServiceRadar features.
- Keep migrations, DDL, bootstrap, and session-sensitive behaviors safe.
- Provide observable pooler health and saturation signals.

## Non-Goals
- Replace application-side workload isolation or per-service pool budgeting.
- Add PgBouncer to Docker Compose in this change.
- Route every database connection through transaction pooling unconditionally.
- Change CNPG storage, backup, failover, or extension-management behavior.

## Decisions

### Use CNPG Pooler resources
The Helm chart should render `postgresql.cnpg.io/v1` `Pooler` resources when `cnpg.pooler.enabled=true`. The primary initial pooler should be an RW pooler bound to the configured CNPG cluster.

### Prefer transaction pooling for safe runtime query pools
The primary value of PgBouncer for ServiceRadar is multiplexing many application client connections onto fewer Postgres backends. That requires transaction pooling for safe clients. Any client routed through transaction pooling must disable named prepared statements, use unnamed prepares, or otherwise be configured for PgBouncer transaction mode.

### Preserve direct CNPG connections for unsafe paths
The direct `cnpg-rw` service remains the required endpoint for:
- migrations and schema bootstrap
- DDL and extension setup
- administrative jobs that need superuser or database-owner semantics
- clients that rely on session state, `LISTEN/NOTIFY`, session-level advisory locks, temporary tables, or named prepared statements that cannot be disabled

Oban notifier behavior must be reviewed explicitly before routing an Oban-owning node through transaction pooling. If a node needs Postgres notifications or other session semantics, that connection path should stay direct or use a separate session pooler.

### Make routing explicit in Helm values
The chart should expose explicit host selection instead of hiding it behind `cnpg.host` alone. Operators should be able to see whether each workload uses:
- direct CNPG RW service
- PgBouncer RW transaction pooler
- an optional session pooler if added later

## Risks / Trade-offs
- Transaction pooling can break clients that assume session affinity. Mitigation: route only reviewed clients through the transaction pooler and keep a direct bypass.
- PgBouncer can move queueing from Postgres into the pooler. Mitigation: add pool saturation metrics and document sizing.
- CNPG Pooler availability depends on the CNPG operator and CRD version. Mitigation: gate rendering behind `cnpg.pooler.enabled` and document prerequisites.
- PgBouncer is not a substitute for bad queries. Mitigation: keep existing slow-query telemetry, workload isolation, and query-budget work.

## Rollout Plan
1. Add Helm values and render a disabled-by-default or explicitly gated pooler template.
2. Wire demo values to enable the pooler with conservative sizing.
3. Route reviewed application query pools through the pooler and keep migrations/bootstrap direct.
4. Deploy to `demo` and verify all services become healthy.
5. Validate MTR, analytics, logs, login, agent heartbeat, and background job behavior under normal demo load.
6. Add monitoring docs and operational commands for inspecting pooler state.

## Open Questions
- Which workloads should initially use the transaction pooler: web-ng read/query pools, core control-plane pool, core background pool, db-event-writer, or a narrower subset?
- Whether Oban nodes should remain direct or get a dedicated session pooler.
- Whether CNPG Pooler metrics are already scraped in demo or require additional PodMonitor/service annotations.
- What default pool sizes are appropriate for small, medium, and large Helm installs.
