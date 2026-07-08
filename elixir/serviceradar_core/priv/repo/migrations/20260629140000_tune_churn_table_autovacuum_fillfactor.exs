defmodule ServiceRadar.Repo.Migrations.TuneChurnTableAutovacuumFillfactor do
  @moduledoc """
  Per-table storage tuning for the two highest-churn write paths (fj #33 demo CPU).

  These are catalog-only `ALTER TABLE ... SET (...)` changes — no table rewrite — so
  they apply immediately to future writes (existing rows are unaffected; a one-time
  `VACUUM`/`pg_repack` would reclaim already-accumulated bloat, done out of band).

  NOTE: the larger remaining lever is cluster-level, not per-table — the demo's
  checkpoints are WAL-volume-forced (`num_timed=0`), so `max_wal_size 1GB -> 4-8GB`
  + `checkpoint_completion_target=0.9` on the CNPG cluster would smooth the fsync
  bursts. That is a CNPG config change (gitops), not an app migration.
  """
  use Ecto.Migration

  def change do
    # flow_process_attribution_current: ~25.4M rows under heavy UPDATE churn. fillfactor
    # is already 80; the gap is autovacuum cadence — the default scale_factor 0.2 lets
    # ~5M dead tuples accumulate before a vacuum, producing the bursty autovac + WAL
    # spikes seen on demo. Tighten to 0.02 (~0.5M) so vacuums run smaller and more often.
    execute(
      """
      DO $$
      BEGIN
        IF to_regclass('platform.flow_process_attribution_current') IS NOT NULL THEN
          ALTER TABLE platform.flow_process_attribution_current SET (
            autovacuum_vacuum_scale_factor = 0.02,
            autovacuum_analyze_scale_factor = 0.02
          );
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF to_regclass('platform.flow_process_attribution_current') IS NOT NULL THEN
          ALTER TABLE platform.flow_process_attribution_current RESET (
            autovacuum_vacuum_scale_factor,
            autovacuum_analyze_scale_factor
          );
        END IF;
      END $$;
      """
    )

    # gateways: a single-row table updated ~557k×/window (last_seen/updated_at heartbeats).
    # Only gateway_id is indexed, so the updates are HOT-eligible — but the default
    # fillfactor=100 reserves no in-page free space. Reserve 30% so each heartbeat is a
    # Heap-Only Tuple update (no index maintenance, in-page dead-tuple pruning) instead of
    # spilling versions across pages.
    execute(
      """
      DO $$
      BEGIN
        IF to_regclass('platform.gateways') IS NOT NULL THEN
          ALTER TABLE platform.gateways SET (fillfactor = 70);
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF to_regclass('platform.gateways') IS NOT NULL THEN
          ALTER TABLE platform.gateways RESET (fillfactor);
        END IF;
      END $$;
      """
    )
  end
end
