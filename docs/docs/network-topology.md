---
title: Network Topology
---

# Network Topology

The Network Topology view is the high-density topology experience for large
graphs with causal blast-radius overlays. The overview renders server-authored
world tiles fetched by zoom level; drill-down opens bounded ELK detail scenes.

## Feature Flag

The Network Topology view is controlled by:

- `SERVICERADAR_GOD_VIEW_ENABLED=true|false`

Runtime behavior:

- `false` (default): `/topology` is hidden/disabled.
- `true`: `/topology`, the topology channel stream, and the world-tile and
  latest-snapshot endpoints are available.

### Serving model

The overview is a quadtree of world tiles over a persisted, versioned radial
ELK layout. The background worker composes bounded ELK batches before publishing
coordinates; individual tiles never run their own layout. Ordinary additions
preserve existing positions, while a staged layout upgrade or explicit relayout
can replace the coordinate space.
The client fetches only the tiles in the viewport, keyed by
`layout_version`/`z`/`x`/`y`, and renders schema-3 Arrow batches; telemetry
(health and interface rates) rides a separate per-tile overlay so geometry
tiles stay cached. Zoom reveals aggregates first, then backbone, infrastructure
and endpoints, subject to density limits. Large populations remain navigable
as groups rather than requiring every device or label on screen at once.
Reset view fits the active devices. Searching for a device resolves its world
coordinates and flies to them; opening a device or attachment group enters a bounded ELK detail scene
and returns to the tile map on exit. These bounded map pages reuse the radial
overview projection, including real attachment fans; older detail payloads
without that profile retain their layered layout.

The tiled world reads Dgraph's admitted topology view, including fresh and
last-known stale attachment, hosted and inferred evidence alongside the canonical
backbone. Stale links remain visible and marked stale, but never supply current
traffic or packet animation. The separate canonical traversal API remains
backbone-only. Overview routes follow the preferred physical-first forest;
retained cross-links remain available in bounded details. Zoom changes grouping and label admission, not device coordinates.

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

The migrator and core's dual-write copy must select the same canonical set,
because `rebuild` deletes every canonical edge it was not given. God View reads
Dgraph's admitted topology view directly; it includes eligible attachment,
hosted and inferred evidence in addition to canonical edges. The canonical
predicate has one definition in
`RuntimeTopologyProjection.canonical_edge_predicate/3`; the migrator's Cypher
repeats it verbatim.

### Reconciliation after the backend cutover

With `GRAPH_BACKEND=dgraph` (`graph.backend: dgraph` in Helm), core's
`TopologyGraph.rebuild_canonical_links_from_current/0` reconciles the
policy-approved mapper evidence and existing canonical edges in Dgraph through
the existing typed replacement API. It does not read AGE adjacency or refresh
the SQL topology projection. `age` and `dual` retain their AGE reconciliation
path; `dual` copies the resulting canonical set to Dgraph.

The Dgraph path preserves directional interface attribution, existing canonical
telemetry, and observation timestamps. Retained edges participate in same-port
conflict resolution with their stored support rank. Reconciliation retains the
starvation and mass-deletion guards for stale pruning. Its fingerprint and
heartbeat persist in CNPG under a separate projection key so switching backends
cannot reuse the other store's fingerprint.

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

### Dgraph reset during AGE/dual migration

Use this procedure while AGE is still receiving topology writes. After
`GRAPH_BACKEND=dgraph`, use the core reconciliation path above: the migrator
still reads AGE and can replace current Dgraph topology with stale adjacency.

To rebuild the migration target from current observations:

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

- Zoom mode (`auto`, `world`, `region`, or `detail`)
- Health toggles (`unavailable`, `healthy`, `unknown`)
- Layer toggles (links, traffic, and opt-in inferred relations)

Interpretation:

- `healthy`: last observed available
- `unavailable`: last observed unavailable
- `unknown`: not yet observed

Health is availability only, independent of geometry and causality; it does not
imply a causal `root_cause`/`affected` status.

## Known Limitations

- Rendering requires WebGPU; unsupported clients receive an error rather than a fallback renderer.
- Performance depends on browser/GPU capability. Authenticated million-device product acceptance remains pending.
- Large revisions may be dropped under budget pressure to preserve interaction responsiveness.
- Causal confidence is bounded by telemetry quality/completeness.

## Telemetry and Signals

### Link traffic

World-tile traffic uses the shared telemetry reader: StarRocks while enabled,
CNPG otherwise. It does not read the frozen CNPG history when warehouse writes
are enabled. Only fresh, unambiguous physical interface measurements can drive
packets. Attachment, inferred and hosted evidence does not supply traffic.

A fully selected bundle can animate its measured contribution even when some
selected bindings have no telemetry. Complete totals remain unknown and observed
coverage is reported separately. Bundles with unselected membership do not
animate; rates are never extrapolated across telemetry pages. Bounded detail
scenes currently have no live traffic overlay.

### Canonical graph telemetry refresh

Link traffic shows packets per second (pps) and bits per second (bps), derived
from cumulative interface counters. Each interval uses two samples from the
same collector and metric series within the last 30 minutes; octet rates are
converted to bits per second. For each device/IP, interface and metric, the
freshest producer is selected before validating its interval. A reset, negative
sample, invalid interval or single sample yields no rate; it does not fall back
to an older collector's traffic.

Both telemetry backends use the shared SRQL-compatible wrap and plausibility
rule in `ServiceRadar.Analytics.StarRocks.MetricConsumers.counter_rate_sql/1`.
CNPG supplies the producer's `max_counter_rate_per_second` metadata when present.
The StarRocks reader has no producer ceiling, so it uses the rule's default
32-bit wrap bound and rejects 64-bit decreases. A decrease without enough
metadata to distinguish a plausible 32-bit wrap from a reset can still be
interpreted as a wrap.

With `graph.backend: dgraph`, telemetry refresh updates only existing canonical
edges' directional traffic, capacity and telemetry eligibility. It preserves
discovery evidence, `last_seen` and endpoints, and cannot recreate a pruned edge.
In `dual` mode, refresh still updates AGE before the canonical rebuild copies
edges to Dgraph.

### Operational metrics

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
