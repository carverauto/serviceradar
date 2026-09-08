# Tasks — fix-topology-evidence-pipeline-resilience

## 1. Restore evidence ingestion (hotfix tier)
- [x] 1.1 Add `constraints allow_empty?: true, trim?: false` to `TopologyLink` logical-key string attributes (`neighbor_port_id`, `neighbor_device_id`, `neighbor_chassis_id`, `protocol`, `local_device_id`) in `topology_link.ex`; verify `default ""` + explicit `""` both persist
- [x] 1.2 Regression tests: ingest real-shaped payloads for SNMP-L2 ARP+FDB (`neighbor_port_id: nil`), UniFi wireless client, UniFi uplink, wireguard-derived; assert rows persist and `TopologyGraph.upsert_links/1` is invoked
- [x] 1.3 Rework `handle_bulk_result/2` (`mapper_results_ingestor.ex`): partial success returns accepted records + rejection summary instead of `{:error, errors}`; keep TimescaleDB chunk-pkey special case; audit the other `insert_bulk` call sites (`mapper_interfaces`, discovered interfaces) for the same semantics
- [x] 1.4 `ingest_topology/2` proceeds to AGE upsert with accepted records; rejected records emit `[:serviceradar, :mapper_topology, :ingest_rejected]` telemetry (reason, protocol, agent_id) and error-level sampled logs
- [ ] 1.5 Verify on demo: SNMP-L2/UniFi-API rows resume in `platform.mapper_topology_links`; `CANONICAL_TOPOLOGY` repopulates on next rebuild; god-view shows connected backbone again

## 2. Starvation defense in canonical rebuild
- [x] 2.1 Add evidence-freshness tracking: last-accepted evidence timestamp per (protocol, agent) exposed via telemetry + `canonical_topology_rebuild_stats`; raise an actionable core-side health alert when `mapper_topology` payloads keep arriving for an (agent, protocol) but acceptance stays frozen past the freshness window
- [x] 2.2 Starvation guard: when `after_upsert_edges == 0` (or < configurable floor) while `mapper_evidence_edges > 0`, SKIP the stale prune, emit `canonical_rebuild_starved` health event; add defense-in-depth cap (refuse to prune >50% of canonical edges in one pass without override)
- [x] 2.3 Self-heal escalation across BOTH recovery mechanisms — `CanonicalRebuild.maybe_self_heal_zero_canonical` (canonical_rebuild.ex:369) and the separate one-shot recovery in `TopologyStateCleanupWorker` (topology_state_cleanup_worker.ex:96): ending with 0 canonical edges while evidence exists logs at error level, emits a health event, and stops claiming "completed"; repeat occurrences deduplicate into a persistent unhealthy state visible in the UI
- [x] 2.4 Tests: frozen-evidence scenario (evidence older than cutoff) must not delete existing canonical edges and must raise the starved signal; normal topology-change scenario still prunes

## 3. Endpoint attachment identity (switch↔host edges)
- [x] 3.1 Replace blanket suppression in `suppress_topology_sighting_candidate?` with provisional identity minting for `snmp-arp-fdb` and UniFi client neighbors: `sr:` uid keyed by normalized MAC + partition, `identity_state: provisional`, confidence tier from evidence class; provisional devices are merge-inert (never absorb identifiers from corroborated devices; distinct MACs never merge)
- [x] 3.2 Remove the non-`sr:` fallback in `topology_graph/projection/payload.ex` (`neighbor_device_id ← mgmt_addr ← chassis_id ← system_name`); unresolved neighbors are dropped with a counter, never written to AGE
- [x] 3.3 Config flag (default off for one release) gating 3.1; enablement runbook: watch `device_identifiers` growth + inventory counts on demo
- [x] 3.4 Diagnose UniFi wired `port_links` extraction always returning 0 (`go/pkg/mapper/ubnt_topology.go` `processPortTable`) against a live controller; add fixture-based parity test
- [x] 3.5 E2E test: FDB attachment for an un-inventoried host produces a renderable `sr:`↔`sr:` attachment edge surviving canonical rebuild + runtime projection

## 4. God-view backbone-empty signal
- [x] 4.1 Add `backbone_edge_count` (and per-class edge counts) to the god-view snapshot meta (`god_view_stream.ex`)
- [x] 4.2 Render a warning state in the topology UI when backbone count is 0 (chip + call-to-action to enable attachment/inferred layers); status line includes per-class counts
- [x] 4.3 Playwright check: empty-backbone snapshot renders the warning; healthy snapshot does not

## 5. Rollout & verification
- [ ] 5.1 Deploy tier-1 (tasks 1.x) to demo; confirm `Mapper topology ingestion failed` warnings stop and edges return within one rebuild cycle
- [ ] 5.2 Deploy tier-2/3/4 behind flags; enable endpoint identities on demo; screenshot before/after god-view for the change record
- [ ] 5.3 Backfill note: no data surgery — evidence re-accumulates from live mapper pushes; document expected convergence time (one push interval + one rebuild)
