# GodView Rollout and Verification Runbook

## Feature Flag and Rollback

- Runtime graph is canonical-only.
  - Runtime graph reads only `:CANONICAL_TOPOLOGY` edges.
  - Legacy mapper-interface fallback query mode is removed from web-ng runtime graph ingestion.
- Rollback strategy is now operational, not query-mode toggling.
  - Recover canonical graph via backend rebuild/recovery workflows (`canonical_rebuild` and `cleanup_recovery`) rather than switching to non-canonical reads.

## SLO Gates

Monitor these counters from `god_view_pipeline_stats` and runtime refresh logs:

- Edge parity gate:
  - `edge_parity_delta == 0` (or <= 2 transiently during refresh windows).
- Unresolved directional gate:
  - `edge_unresolved_directional / final_edges <= 0.25`.
- Telemetry attachment gate:
  - `edge_telemetry_interface / final_edges >= 0.50` for SNMP-dense environments.
- Animated edge parity gate:
  - `edge_telemetry_interface` should track visible animated edges in UI within +/-10%.

## Post-Deploy Checks

1. Confirm runtime refresh is healthy:
   - `runtime_graph_refresh fetched=<n> ingested=<n>` with `fetched > 0`.
2. Confirm canonical rebuild observability in core:
   - Telemetry events:
     - `[:serviceradar, :topology, :canonical_rebuild, :completed|:failed]`
     - `[:serviceradar, :topology, :cleanup_rebuild, :completed|:failed]`
     - `[:serviceradar, :topology, :cleanup_recovery, :triggered|:completed|:failed]`
3. Confirm no canonical collapse:
   - `after_prune_edges` should stay above configured threshold.
4. Confirm directional fields are present:
   - `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba` non-zero on known active links.

## Troubleshooting

- Symptom: empty/sparse topology after deploy.
  - Check canonical rebuild logs and telemetry counts (`before_edges`, `after_upsert_edges`, `after_prune_edges`).
  - If canonical edges collapse while mapper evidence exists, trigger recovery/rebuild and verify refresh counts (`runtime_graph_refresh fetched=<n> ingested=<n>` with `n > 0`).
- Symptom: topology present but reduced animations.
  - Check `edge_telemetry_interface` and `edge_unresolved_directional`.
  - Verify interface attribution fields (`local_if_index_ab`, `local_if_index_ba`) are present in runtime rows.
- Symptom: frequent recovery triggers.
  - Investigate mapper evidence freshness and stale pruning windows.
  - Validate SNMP-L2/LLDP evidence ingestion cadence and agent reachability.

## Return to Stable State

After canonical rebuild stability is restored:

1. Confirm `after_prune_edges` remains stable above threshold for multiple cycles.
2. Confirm runtime refresh remains non-zero and stable over multiple intervals.
3. Re-validate SLO gates.
