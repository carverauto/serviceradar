## Context
ServiceRadar already treats metrics as source-neutral telemetry that must be published to JetStream before persistence. Issue 3790 extends that model to cgroup-v2 hosts where a single device can host many tenant workloads. The product must not create a new stream, table, or UI family for one collector just because the source is cgroup-v2.

The counter behavior needed for `cpu.stat` and `io.stat` is specified in `add-monotonic-counter-metric-semantics`. This change builds on that contract by adding cgroup identity and collection scope.

## Goals / Non-Goals
- Goals: collect cgroup-v2 CPU, memory, process, and IO metrics; preserve tenant/workload identity as metric attributes; publish through the unified JetStream metric path; expose useful per-tenant views.
- Non-Goals: add a separate cgroup-specific metrics stream; trust tenant IDs supplied by untrusted plugins or workloads; require every deployment to model tenants as first-class database resources on day one.

## Decisions
- Decision: cgroup metrics use the same metric event envelope as host and plugin metrics.
  - Rationale: a user-provided collector that reports CPU, memory, disk, or network metrics should land in the same downstream shape regardless of source.
- Decision: the top-level resource remains the agent/device host, and cgroup identifiers are stored as attributes or dimensions on each metric point.
  - Rationale: the host is the attested identity. A cgroup path, tenant ID, container name, or Kubernetes label is contextual and can be spoofed unless bound to the gateway/agent ingest identity.
- Decision: cgroup reset anchors are per cgroup, not per host.
  - Rationale: a cgroup can be deleted and recreated without a reboot, so host boot time alone is not enough to distinguish counter resets from continued accumulation.
- Decision: initial UI surfaces are tables and drilldowns, not a separate resource hierarchy.
  - Rationale: the immediate operator need is "which tenant/cgroup is consuming resources on this host?" First-class cgroup resources can be added later if query patterns prove they are needed.

## Risks / Trade-offs
- High-cardinality cgroup paths can increase storage and query cost. Mitigation: collector include/exclude filters, path normalization, and bounded default collection scope.
- Tenant labels may be untrusted. Mitigation: mark cgroup and tenant attributes as observed metadata scoped to the attested agent/device, not authorization identities.
- Some hosts may not run cgroup-v2 or may lack permissions. Mitigation: detect support at runtime and publish health/status rather than failing the whole sysmon collector.

## Migration Plan
1. Ship cgroup collection disabled by default or scoped to configured roots.
2. Emit cgroup metrics through the unified metric pipeline with reset anchors and raw counters.
3. Add SRQL/web views that only appear when cgroup metrics are present.
4. Revisit first-class cgroup or tenant resources after query/cardinality data is available.
