# Design — fix-topology-evidence-pipeline-resilience

## Context

Full causal chain verified live on demo (2026-07-04), with git archaeology in
this repo. Timeline:

| When | Event |
| --- | --- |
| 2026-06-25 07:51 | `fed249e6f` deploys to demo (same window as the device-identifier purge that produced `platform.device_purge_salvage_20260625`, 472k rows). Last SNMP-L2/UniFi-API/wireguard evidence rows written (`platform.mapper_topology_links` max `created_at` = 07:51:15). |
| 2026-06-25 → now | Every mapper payload containing FDB/UniFi-wireless/wireguard records fails partially; `handle_bulk_result` treats it as total failure; AGE mapper evidence frozen. Hourly `Mapper topology ingestion failed ... Required{field: :neighbor_port_id}` (×64), `:neighbor_device_id` (×12), `:neighbor_chassis_id` (×4) per cycle across two agents. |
| 2026-07-01 22:40 | Demo rolls v1.4.0; agents restart; symptom unchanged (bug is in core, present since `fed249e6f` and still on staging HEAD). |
| 2026-07-02 07:51 | Stale cutoff (10080 min) crosses the frozen evidence: canonical rebuild upserts 0, prune deletes remaining canonical edges. `platform_graph.CANONICAL_TOPOLOGY` = 0 rows since. UI shows islands. |
| hourly since | `Canonical topology self-heal triggered` → `recovery rebuild completed` with `after: 0`. No alert. |

Key mechanics:

- **The Ash cast trap.** `attribute :neighbor_port_id, :string do allow_nil?
  false; default "" end` — Ash `:string` defaults to `allow_empty?: false,
  trim?: true`, so a provided `""` casts to `nil` and fails Required. The
  `blank_to_empty/1` coercion added *in the same commit* was therefore dead on
  arrival. `default ""` only applies when the key is absent, and the ingestor
  always provides the key.
- **Why LLDP/CDP still trickle in.** Those records carry real port ids, so they
  pass validation and (with `stop_on_error?: false`) insert — but because
  `handle_bulk_result` maps partial success to `{:error, _}`, the surviving
  records never reach `TopologyGraph.upsert_links/1`, so even they don't refresh
  AGE. Fresh `mapper_topology_links` LLDP/CDP rows vs. frozen AGE `ATTACHED_TO`
  edges confirmed this split on demo.
- **Server payload is internally consistent; UI can't compensate.**
  `god_view_stream.ex` guarantees every served edge has both endpoints in the
  node set (`Map.fetch!` in `encode_payload`), so the islands are not a
  client-side join bug: the backbone edge *set* is empty and the remaining
  attachment-plane edges are hidden by default layer toggles and excluded from
  layout connectivity (`edgeDrivesBackboneLayout`).

## Goals / Non-Goals

- Goals:
  - No single malformed/rejected record can stop unrelated topology evidence
    from flowing to AGE.
  - Evidence starvation is detected and alarmed; it can never silently delete
    the whole canonical graph.
  - FDB/UniFi-client endpoint neighbors participate in the canonical graph via
    provisional `sr:` identities so switch↔host edges render.
  - Operators can see, from core-side signals alone, that topology ingest is
    unhealthy (no ssh+journalctl archaeology required).
- Non-Goals:
  - New discovery protocols or UniFi feature parity (owned by
    `add-unifi-wifi-discovery-parity`).
  - Carrier-scale read-model rework (owned by
    `refactor-topology-read-model-for-carrier-scale`).
  - Reworking DIRE identity reconciliation beyond the topology-sighting path.

## Decisions

- **Decision: keep NOT NULL `""` sentinels, fix the type constraints.**
  Set `constraints allow_empty?: true, trim?: false` on the logical-key string
  attributes of `TopologyLink`. Alternatives: (a) make columns nullable again
  and use `COALESCE` in the unique index — larger migration, re-opens the
  duplicate-row bloat `fed249e6f` fixed; (b) synthesize placeholder port ids —
  pollutes evidence. The constraint fix is minimal and preserves the
  bloat-prevention upsert.
- **Decision: partial success proceeds.** `handle_bulk_result` returns
  `{:ok, %{accepted: n, rejected: m, errors: sampled}}`; the ingestor calls
  `TopologyGraph.upsert_links/1` with the accepted records and emits telemetry
  for rejected ones. Alternative: pre-validate and split before bulk_create —
  still needed for observability, but the pipeline must be tolerant regardless
  of where rejection happens.
- **Decision: starvation guard in the rebuild, not the prune query.** Compute
  `after_upsert_edges` first; if it is 0 (or < floor) while
  `mapper_evidence_edges > 0`, skip the prune entirely, emit
  `canonical_rebuild_starved` telemetry + health event. Alternative: cap prune
  percentage per pass — retained as defense-in-depth (never delete >50% of
  canonical edges in one pass without operator override).
- **Decision: provisional endpoint identities are minted, tiered, and
  GC-able.** Replace the blanket `snmp-arp-fdb`-without-sysname suppression
  with: mint `sr:` provisional device keyed by normalized MAC (partition
  scoped), `identity_state: provisional`, `confidence_tier` from evidence class,
  eligible for existing tombstone GC if never corroborated. This reuses the
  existing `promote_topology_sightings` machinery rather than adding a new
  reconciler. Guardrail (per DIRE lessons): provisional devices are
  merge-inert — they may be merged INTO corroborated devices but never absorb
  identifiers from them, and distinct MACs stay distinct devices.
- **Decision: don't write non-`sr:` vertices to AGE.** The projection payload
  fallback (`neighbor_device_id ← mgmt_addr ← chassis_id ← system_name`) is
  removed; unresolved neighbors are dropped with a counter. The fallback only
  produced invisible pseudo-nodes that every consumer filters out — it is
  dead weight that also bloats the graph.
- **Decision: UI surfaces backbone-empty as a state, not a heuristic.** The
  snapshot payload already computes component stats; add
  `backbone_edge_count` to the payload meta and render a warning chip +
  "show attachment layers" call-to-action when it is 0. Auto-enabling layers
  silently was rejected: it would mask the underlying outage.

## Risks / Trade-offs

- Accepting empty-string keys re-admits low-quality evidence rows → mitigated by
  the logical-key upsert (no row growth) and rejected-record telemetry.
- Provisional endpoint devices could re-inflate `device_identifiers` (the
  2026-06-25 purge removed 472k rows) → mitigated by MAC-keyed dedup,
  confidence tiers, corroboration-based GC, and the merge-inert guardrail;
  monitored via inventory counts.
- Skipping prune during starvation can leave truly-dead edges visible longer →
  acceptable: stale-but-connected beats silently-empty; the dead-man alert
  drives a human to fix ingest.
- Behavior change in `handle_bulk_result` affects `mapper_interfaces` and other
  bulk ingestors sharing the helper → audit call sites; keep the
  TimescaleDB-pkey special case.

## Migration Plan

1. Ship constraint fix + partial-success handling + tests (restores ingest; on
   demo, evidence re-accumulates on the next hourly mapper push and the next
   rebuild repopulates `CANONICAL_TOPOLOGY`; no data surgery needed).
2. Ship starvation guard + self-heal escalation + freshness telemetry.
3. Ship endpoint-attachment identity promotion + AGE pseudo-vertex removal
   (behind a config flag for one release; enable on demo first and watch
   device-inventory counts).
4. Ship god-view backbone-empty signal.
Rollback: each step is independently revertible; step 3's flag defaults off.

## Open Questions

- Should the stale window scale with observed push cadence (e.g. N missed
  heartbeats) instead of wall-clock minutes? (Default 180 min assumes 5-minute
  mapper pushes; demo pushes hourly and needed 10080.)
- UniFi wired `port_links` extraction currently yields 0 links on demo
  (`port_links:0` in extraction summary) — bug or site config? Needs a
  reproduction against a real controller during implementation.
