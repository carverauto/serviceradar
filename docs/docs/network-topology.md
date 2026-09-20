---
title: Network Topology
---

# Network Topology

The Network Topology view is the high-density topology experience for large graphs with causal blast-radius overlays.

## Feature Flag

The Network Topology view is controlled by:

- `SERVICERADAR_GOD_VIEW_ENABLED=true|false`

Runtime behavior:

- `false` (default): `/topology` is hidden/disabled.
- `true`: `/topology`, topology channel stream, and latest snapshot endpoint are available.

## Rollout Guidance

Recommended rollout order:

1. Enable in a non-production environment first.
2. Validate stability and performance.
3. Enable broader environments only after SLO validation.

For Helm-based deployments:

- Set `webNg.extraEnv.SERVICERADAR_GOD_VIEW_ENABLED: "true"` in the target values file.

## Dgraph topology store

Mapper evidence stays in CNPG (`mapper_topology_links`, `runtime_topology_links`).
Dgraph is the traversal graph. During rollout, `graph.backend` defaults to
`dual` and `graph.read` stays `age` until the migrator checksum is green.

The Helm post-install Job `serviceradar-dgraph-migrator` (and the Compose
one-shot `age-to-dgraph`) runs the Bazel `age-to-dgraph` binary:

1. `rebuild` — canonical edges from relational evidence into Dgraph (idempotent).
2. `checksum` — AGE `platform_graph` vs Dgraph node/edge counts and content hash.

A checksum failure fails the Job and does **not** flip `graph.read`. Cutover is
an operator values change (`graph.read: dgraph`), with rollback `graph.read: age`.

### Operator-safe Dgraph reset

To clear a polluted Dgraph topology and rebuild from current observations:

1. Record pre counts: `AGE_TO_DGRAPH_MODE=checksum` (or inspect God View).
2. Reset mapper evidence using the existing topology-evidence cleanup (CNPG
   `mapper_topology_links` / `runtime_topology_links` stay the source of truth;
   do not `drop_all` on Dgraph).
3. Run `age-to-dgraph rebuild`. The binary prints `pre_edges` / `post_edges` /
   `upserted`.
4. Run `age-to-dgraph checksum`. Leave `graph.read` at `age` until it passes.

Lab graphs with no evidence tables may use `dump-load` with
`AGE_TO_DGRAPH_ALLOW_LAB_DUMP=1` and a synthetic JSON fixture. Live AGE dumps
must not enter git.

`in:graph_cypher` continues to query AGE until AGE is retired. `in:graph` /
`in:graph_dql` query Dgraph.

## Operator Controls

Primary controls in the Network Topology view:

- Causal filter toggles (`root_cause`, `affected`, `healthy`, `unknown`)
- Visual ghosting/highlight controls
- Semantic zoom mode
- Structural reshape actions (collapse/expand paths)

Interpretation:

- `root_cause`: primary fault origin
- `affected`: blast-radius impacted nodes
- `healthy`: unaffected nodes
- `unknown`: insufficient/conflicting evidence

## Known Limitations

- Performance depends on browser/GPU capability; WebGPU-capable clients perform best.
- Unsupported WebGPU clients run in fallback mode with reduced throughput.
- Large revisions may be dropped under budget pressure to preserve interaction responsiveness.
- Causal confidence is bounded by telemetry quality/completeness.

## Telemetry and Signals

The Network Topology view emits operational telemetry for:

- Snapshot build latency
- Snapshot payload size
- Snapshot dropped count
- Snapshot error count

Use these metrics to validate rollout health and SLO readiness.

## Troubleshooting

### `/topology` is not visible

- Confirm `SERVICERADAR_GOD_VIEW_ENABLED=true` for `web-ng`.
- Confirm the pod has restarted with updated env.

### Stream fails to join (`god_view_disabled`)

- Feature flag is disabled at runtime.
- Verify `web-ng` runtime env and effective config.

### Snapshot decode errors

- Check schema/version compatibility between server and client.
- Verify latest deployed frontend bundle matches backend snapshot contract.

### Frequent dropped snapshots

- Check snapshot budget configuration and host load.
- Reduce update pressure and verify telemetry around build time and drop counts.
