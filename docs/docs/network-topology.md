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

1. `rebuild` — canonical edges from AGE into Dgraph (idempotent). The source is
   AGE's `CANONICAL_TOPOLOGY` edges, not `runtime_topology_links`: that table is
   a row-capped God View cache, and rebuild deletes every key it does not send,
   so a fleet larger than the cap would have its extra edges removed. Mapper
   evidence is the fallback when AGE holds no canonical edges. Only the
   canonical set is rebuilt: `relation_type` in `CONNECTS_TO` / `LOGICAL_PEER` /
   `HOSTED_ON`, or an empty `relation_type` with a direct evidence class.
   Attachment-plane evidence (`ATTACHED_TO` / `OBSERVED_TO`, inferred segments)
   is not backbone topology and is never promoted to a canonical edge.
2. `checksum` — AGE `platform_graph` vs Dgraph node/edge counts and content hash.
   Both sides recompute edge identity in the Dgraph key format rather than
   hashing whichever key each store happens to hold, and `node_count` is the
   number of distinct devices appearing on those canonical edges, not every
   `:Device` vertex, which the Dgraph side has no reason to carry.

A checksum failure fails the Job and does **not** flip `graph.read`. Cutover is
an operator values change (`graph.read: dgraph`), with rollback `graph.read: age`.

The migrator, core's dual-write copy, and the projection that feeds God View
must all select the same canonical set, because `rebuild` deletes every
canonical edge it was not given. The predicate has one definition in
`RuntimeTopologyProjection.canonical_edge_predicate/3`; the migrator's Cypher
repeats it verbatim.

### Dgraph superuser credentials

With the in-chart cluster (`dgraph.enabled=true`), the `groot` password is
generated into the Dgraph ACL Secret alongside the ACL HMAC key, and the
post-install Job `serviceradar-dgraph-acl-bootstrap` rotates the cluster off
Dgraph's well-known default before the schema Job runs. Application pods and
both Jobs read it through `DGRAPH_PASSWORD`; nothing embeds a literal password.

An external cluster (`dgraph.enabled=false` with `dgraph.external.host`) is not
provisioned by this chart, so an ACL credential for it must already exist as a
Secret in the namespace: point `dgraph.external.credentialsSecret` (and
`credentialsKey`, default `password`) at it, with `dgraph.external.username`
naming the ACL user. Leave `credentialsSecret` empty to dial an external
cluster that has ACL disabled. A password is never a chart value, because
`graph.env` renders into the Deployment spec.

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
`in:graph_dql` query Dgraph. Both entities are described in the
[SRQL Language Reference](./srql-language-reference.md).

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
