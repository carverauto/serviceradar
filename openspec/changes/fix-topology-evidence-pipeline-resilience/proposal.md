# Change: Make the mapper→AGE topology evidence pipeline resilient to per-record failures and evidence starvation

## Why

The demo topology graph collapsed into disconnected islands because the evidence
pipeline has no failure isolation and no starvation defense. A validation change
shipped on 2026-06-25 (`fed249e6f`, "DIRE bloat prevention") silently rejected
every SNMP-L2 FDB, UniFi wireless/uplink, and wireguard-derived topology record
for nine days; seven days later the canonical rebuild's stale prune deleted the
entire `CANONICAL_TOPOLOGY` edge set (0 edges), and the hourly "self-heal"
declared success with zero edges every hour without alerting anyone.
Separately — and pre-dating the regression — switch↔host attachment edges have
*never* rendered because endpoint neighbors discovered via ARP/FDB and UniFi
client tables never resolve to canonical `sr:` device ids and are filtered out
of every downstream view.

Verified root-cause chain (live demo evidence + code):

1. **Ash empty-string trap (regression trigger).** `TopologyLink`
   (`elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_link.ex:119`)
   made the logical-key columns `allow_nil? false` with `default ""`. The
   ingestor coerces `nil → ""` (`normalize_topology_link_key`,
   `mapper_results_ingestor.ex:3254`), but Ash's `:string` type defaults to
   `trim?: true, allow_empty?: false`, which casts `""` back to `nil` — so every
   record without a `neighbor_port_id` (all FDB attachments, UniFi wireless
   clients, wireguard links) fails `Required` validation. Live demo cores log
   `Mapper topology ingestion failed: ... Ash.Error.Changes.Required{field:
   :neighbor_port_id}` twice per hour since 2026-06-25 07:51.
2. **All-or-nothing pipeline.** `Ash.bulk_create` runs with
   `stop_on_error?: false`, but `handle_bulk_result`
   (`mapper_results_ingestor.ex:3299`) converts *partial* success into
   `{:error, errors}`, so `TopologyGraph.upsert_links/1` is never called — even
   the LLDP/CDP records that inserted successfully never reach the AGE graph.
   Mapper evidence in AGE froze at 2026-06-25 07:51.
3. **Starvation self-destruct.** The canonical rebuild only upserts edges whose
   evidence is newer than `stale_cutoff` (demo:
   `SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES=10080`, 7 days; default 180
   minutes). When ingest froze, the cutoff crossed the frozen evidence on
   2026-07-02 and the prune deleted every canonical edge
   (`canonical_topology_rebuild_stats %{mapper_evidence_edges: 675,
   after_upsert_edges: 0, after_prune_edges: 0}`). Nothing distinguishes
   "topology changed" from "evidence stopped arriving".
4. **Self-heal theater — in two places.**
   `maybe_self_heal_zero_canonical` (`canonical_rebuild.ex:369-400`) re-runs
   the same upsert against the same stale evidence and returns
   `%{status: :completed}` with no zero-edge check; separately, the one-shot
   recovery in `TopologyStateCleanupWorker`
   (`topology_state_cleanup_worker.ex:96`) re-runs the full rebuild and
   unconditionally logs "Canonical topology recovery rebuild completed" (and
   emits `:cleanup_recovery, :completed` telemetry) even when the retry still
   yields 0 edges — hourly, forever, at info/warning level. Neither path emits
   an error-level log, health event, or alarm on a zero-edge outcome.
5. **Endpoint attachment identity gap (never worked).** The only switch↔host
   producers are SNMP-L2 ARP+FDB correlation
   (`go/pkg/mapper/snmp_l2_query.go:27`) and UniFi port/wireless-client tables
   (`go/pkg/mapper/ubnt_topology.go`). Their neighbors are keyed by MAC/IP only;
   core resolution (`mapper_results_ingestor.ex` `resolve_topology_uid`) fails
   for hosts that aren't already devices with matching mac/ip;
   `suppress_topology_sighting_candidate?` suppresses sightings matching the
   4-way conjunction protocol `snmp-l2` + confidence reason
   `single_identifier_inference` + source `snmp-arp-fdb` + blank system name
   (i.e. exactly the ordinary hosts behind switch ports), so no `sr:` device is
   ever minted; the AGE projection then fabricates raw-IP/MAC
   pseudo-vertices (`topology_graph/projection/payload.ex:81`) which the
   canonical rebuild (`queries/canonical_rebuild.ex:148`) and runtime projection
   (`runtime_topology_projection.ex:30,98`) filter out via `STARTS WITH 'sr:'`
   gates on both endpoints. Net: k8s nodes and other hosts can never connect to
   a switch in the rendered graph.
6. **UI hides what's left.** The god-view defaults
   (`topologyLayers = {backbone: true, inferred: false, endpoints: false}`) hide
   attachment/inferred edges, and the client-radial layout only connects
   backbone-class edges (`layout_topology_state_methods.js:1029`), dumping all
   other nodes into island grids. When the backbone is literally empty the UI
   gives no signal — it just renders islands.

## What Changes

- **Fix the ingest contract**: allow empty logical-key strings on `TopologyLink`
  (`constraints allow_empty?: true, trim?: false` on `neighbor_port_id`,
  `neighbor_device_id`, `neighbor_chassis_id`, `protocol`, `local_device_id`) so
  the documented `""` sentinel actually survives Ash casting; add regression
  tests using real FDB/UniFi-wireless/wireguard record shapes (nil port ids).
- **Per-record failure isolation**: partial bulk-create success MUST NOT abort
  the pipeline. Successfully persisted evidence continues to
  `TopologyGraph.upsert_links/1`; rejected records are counted, sampled into
  logs at error level, and exposed as telemetry
  (`mapper_topology_ingest_rejected_total` by reason/protocol).
- **Evidence freshness dead-man switch**: track last-accepted evidence per
  protocol per agent; when agents keep pushing (`mapper_topology` payloads
  arriving) but acceptance stays frozen, raise an actionable health alert.
- **Prune floor / starvation guard**: the canonical rebuild MUST NOT prune the
  graph to (or near) zero when the upsert produced zero edges from non-empty
  evidence; refuse mass-deletion when the cause is evidence staleness rather
  than topology change, and log/alert instead.
- **Honest self-heal**: a recovery rebuild that ends with zero canonical edges
  while mapper evidence exists is a FAILURE — escalate (error log + health
  event + telemetry), do not report completion.
- **Endpoint attachment identity (fixes "clusters never connect")**: mint
  provisional `sr:` devices (confidence-tiered, MAC-keyed) for FDB/UniFi-client
  neighbors instead of suppressing them wholesale; stop writing non-`sr:`
  pseudo-vertices into AGE (resolve or drop-with-counter). Wired UniFi
  `port_links` extraction (currently always 0 links) gets diagnosed and covered
  by parity tests.
- **God-view empty-backbone signal**: when the served snapshot has zero
  backbone-class edges, surface a visible warning state (and consider
  auto-enabling the endpoints/inferred layers) instead of silently rendering
  islands.
- **Restore demo**: operational runbook step — after the ingest fix deploys,
  evidence re-accumulates on the next mapper pushes and the rebuild repopulates
  `CANONICAL_TOPOLOGY` without manual surgery.

## Impact

- Affected specs: `network-discovery`, `age-graph`, `topology-god-view`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_link.ex`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph/{links.ex,canonical_rebuild.ex,queries/canonical_rebuild.ex}`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/runtime_topology_projection.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`,
    `elixir/web-ng/assets/js/lib/god_view/*`
  - `go/pkg/mapper/{snmp_l2_query.go,ubnt_topology.go}` (parity tests, port-link diagnosis)
- Relationship to in-flight changes (deliberate non-overlap):
  - `improve-mapper-topology-fidelity` (0/17): owns evidence *quality/coverage*
    and carries a MODIFIED delta for `Mapper topology ingestion and graph
    projection`; its "Fallback identity when management IP is unavailable"
    scenario already mandates persisting unresolved evidence — this change
    specifies the *enforcement mechanics* (cast-safe sentinels, partial-failure
    isolation) that make that scenario true. This change does NOT modify that
    requirement heading (also modified by `add-multipath-topology-discovery`);
    all its network-discovery deltas are standalone ADDED requirements.
  - `refactor-topology-read-model-for-carrier-scale` (0/15): owns
    presentation-tier bounding (backbone vs endpoint census, density budgets).
    Endpoint attachment identity promotion here is upstream of and compatible
    with that bounding: promote-then-attach at ingest, quarantine/bound at
    presentation. Its "Topology quality regressions are surfaced explicitly"
    counters complement (and do not replace) the ingest-freshness dead-man and
    starvation guard specified here.
  - `add-unifi-wifi-discovery-parity` (0/86): owns UniFi controller discovery
    features (wireless AND wired client coverage); the ingest fixes here are a
    *precondition* for its wireless-client records (nil neighbor port ids) to
    survive ingestion at all. This change's task 3.4 only diagnoses the current
    `port_links:0` defect as part of restoring attachment evidence — new wired
    extraction features remain owned by the parity change.
  - Ownership note: `improve-mapper-topology-fidelity` also ADDs a
    device-inventory requirement ("Inventory promotion from topology endpoint
    sightings") that overlaps endpoint promotion. THIS change owns the identity
    mechanics (provisional MAC-keyed `sr:` devices, merge-inert guardrail,
    corroboration GC); that change's inventory-promotion requirement should be
    reconciled to consume these provisional identities rather than defining a
    parallel candidate-record mechanism.
- **BREAKING**: none at API level; `TopologyLink` validation loosens (empty
  strings accepted where they were silently required before).
