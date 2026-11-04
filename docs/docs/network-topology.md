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
coordinates; individual tiles never run their own layout. Additions that leave
the trusted parent tree unchanged preserve existing positions. A change to that
tree, including deletion of a connected endpoint, stages a fresh layout under a
new layout version and keeps the accepted world until that replacement
activates. Timestamp-only observation refreshes do not swap an equally trusted
forest or move unchanged geometry. An operator relayout or a staged layout
upgrade can also replace the coordinate space. Arrow tiles stay bounded; the
[binary path audit](https://github.com/carverauto/serviceradar/blob/staging/docs/topology-binary-path-audit.md) records the remaining
producer and browser copies and the scale evidence still missing.
The optional [bitmap membership protocol](https://github.com/carverauto/serviceradar/blob/staging/docs/topology-bitmap-protocol.md) uses
server-side set queries and bounded binary row overlays without changing tile geometry.
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

Mapper evidence stays in CNPG (`mapper_topology_links`). Dgraph is the only
topology graph: every topology write and read (mapper links, interfaces,
management relations, risk scalars, MTR paths, canonical rebuild, telemetry
refresh, ServiceRadar Atlas, SRQL `in:graph` / `in:device_graph`, and the causal
hydrator) uses it. There is no alternative backend and no fallback. A Helm
release without Dgraph (`dgraph.enabled=false` and no `dgraph.external.host`)
fails to render. If core starts without a resolvable Dgraph endpoint, it logs
an error once and drops topology writes until the endpoint resolves.

### Canonical reconciliation

Core's `TopologyGraph.rebuild_canonical_links_from_current/0` reconciles the
policy-approved mapper evidence and existing canonical edges in Dgraph through
the typed replacement API. It preserves directional interface attribution,
existing canonical telemetry, and observation timestamps. Retained edges
participate in same-port conflict resolution with their stored support rank.
Reconciliation retains the starvation and mass-deletion guards for stale
pruning. Its input fingerprint and heartbeat persist in CNPG
(`runtime_topology_projection_meta`), so an unchanged topology is not rewritten.

### Projection lag

Mapper ingestion commits interface and topology evidence to CNPG first, inside
the result-ingestion lane's worker budget. The Dgraph write runs afterwards as
a `TopologyProjectionWorker` job on the `topology_projection` Oban queue
(`OBAN_QUEUE_TOPOLOGY_PROJECTION`, default 2 per core node). A slow or
unavailable Dgraph therefore delays the graph instead of timing the mapper
result out.

Topology views read the graph, so they trail the CNPG interface and evidence
tables by the job's queue wait plus its run time. One device's interfaces are
written in one Dgraph request, and that device's links in two (endpoints, then
edges), however many interfaces or links it carries.

Each projection job is one device and carries that device id only. When it
runs it reads the current committed discovered interfaces (including aliases)
and mapper topology links for that device, and rewrites that device's graph
state through the same batched writes. The newest of that device's link rows
that sets a field owns its IP and interface fields. For each link the job also
creates the neighbor vertex, the neighbor interface and the edge, and writes
the neighbor device's IP and name and the neighbor interface name the reporting
device observed when it has them; a missing value never erases a known one. A
retry of an older job therefore leaves the graph equal
to that device's latest CNPG rows, including when it runs after a newer job has
already completed. A newer result for the same device replaces a job that has
not started, so a pending backlog collapses to one run per device. Oban keeps at
most one pending job per device; an executing job is not pending, so a result
that lands during a run still schedules the next one. Each graph statement
commits on its own. When a job reads the device's rows it records a watermark
(an md5, computed in SQL, of the full content of the device's interface rows
and of its link rows, so any change to, addition of or removal of a row
changes it), and after a successful projection it reads the watermark again. If it
changed, because a write landed during the run or another run for the device
read newer rows and finished first, the job schedules one follow-up projection
for the device. The graph therefore converges to the newest committed rows.
A job reads only links observed at or after the stale-link cutoff that pruning
uses, so retained rows older than that are neither re-projected nor a reason
for a follow-up. The graph-wide passes (global stale-evidence pruning and the
canonical rebuild) run in a separate `TopologyGlobalPassWorker` job on the same
queue. Each projection schedules it 30 seconds ahead, and it is unique while
pending, so a burst of device projections runs the passes once. A failed projection is logged,
reported as an Oban job exception, and retried with backoff. The ingestion
runtime metrics
(`metrics.ingestion_lanes`) carry a `topology_projection` lane (scheduled,
coalesced, accepted, not accepted and failed projections, with `queue_wait_ms`
and `duration_ms`) and a `dgraph` lane (every Dgraph call's outcome, timeouts
and retries, with `duration_ms` and `queue_wait_ms`).

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

### Dgraph reset

The canonical topology is derived from evidence. To rebuild it, reset mapper
evidence with the existing topology-evidence cleanup (CNPG
`mapper_topology_links` stays the source of truth; never `drop_all` on Dgraph)
and let the next mapper cycle and canonical reconciliation repopulate Dgraph.

`in:graph` / `in:graph_dql` and `in:device_graph` query Dgraph;
`in:graph_cypher` was retired with AGE. The entities are described in the
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

Telemetry refresh updates only existing canonical Dgraph edges' directional
traffic, capacity and telemetry eligibility. It preserves discovery evidence,
`last_seen` and endpoints, and cannot recreate a pruned edge.

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
