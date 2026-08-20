defmodule ServiceRadar.ColdTier.RetentionDdlFenceTest do
  @moduledoc """
  Guards the retention fence at the source level (OpenSpec
  add-tiered-telemetry-offload, task 2.4).

  `drop_chunks` and TimescaleDB retention policies are the only ways
  offloadable data disappears. `ServiceRadar.ColdTier.RetentionFence` is the
  single authority for both on registry tables — but a future migration that
  calls `add_retention_policy`/`drop_chunks` directly would silently bypass
  it and let the TimescaleDB background worker drop un-exported chunks
  (exactly the failure this change exists to prevent).

  So: any NEW migration touching retention DDL for a registry table must go
  through the fence. Historical migrations are grandfathered by the
  allowlist below — they predate the fence and are already applied
  everywhere; on fresh installs the first retention run removes whatever
  they arm, and the exporter's `policy_violations/0` alert catches drift.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.Registry

  @migrations_dir Path.join([__DIR__, "..", "..", "..", "priv", "repo", "migrations"])

  # Migrations that predate the fence. Do NOT add to this list: new retention
  # DDL on a registry table goes through ServiceRadar.ColdTier.RetentionFence.
  @grandfathered ~w(
    20260126121000_retry_timescaledb_hypertables.exs
    20260129154221_add_observability_retention_policies.exs
    20260203120000_create_ocsf_events.exs
    20260203193000_add_ocsf_events_hourly_stats.exs
    20260203204000_ensure_ocsf_events_hourly_stats.exs
    20260207090000_add_ocsf_network_activity_retention_policy.exs
    20260207093000_add_ocsf_network_activity_rollups.exs
    20260207112000_ensure_ocsf_network_activity_rollups.exs
    20260220110000_add_srql_metric_hourly_caggs.exs
    20260301120000_add_flow_traffic_hierarchical_caggs.exs
    20260315120000_ensure_ocsf_events_hourly_stats_cagg.exs
    20260429220000_update_observability_retention_policies.exs
    20260605210000_reconcile_observability_retention_chunks.exs
    20260611040000_align_otel_chunks_retention.exs
    20260611050000_create_spans_red_1h_cagg.exs
    20260611060000_create_otel_metric_points.exs
    20260613070000_add_capacity_forecast_retention_policy.exs
    20260620120000_add_remaining_high_volume_retention_policies.exs
    20260621143000_rebuild_flow_caggs_with_sampling_rate.exs
    20260622183000_fix_timeseries_series_identity_cardinality.exs
    20260622202000_shrink_ocsf_events_chunk_interval.exs
    20260716210000_clamp_cagg_refresh_windows.exs
  )

  test "the grandfather list has no stale entries" do
    present =
      @migrations_dir
      |> Path.expand()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    stale = Enum.reject(@grandfathered, &MapSet.member?(present, &1))

    assert stale == [],
           """
           These entries name migrations that no longer exist:

             #{Enum.join(stale, "\n  ")}

           A stale allowlist entry is not inert -- it silently pre-approves any
           future migration that happens to reuse the filename. Delete them.
           """
  end

  test "new migrations route registry-table retention DDL through the fence" do
    offenders =
      @migrations_dir
      |> Path.expand()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in @grandfathered))
      |> Enum.filter(&arms_registry_retention?/1)
      |> Enum.map(&Path.basename/1)

    assert offenders == [],
           """
           These migrations arm retention DDL (add_retention_policy/drop_chunks)
           on a cold-tier registry table without going through the fence:

             #{Enum.join(offenders, "\n  ")}

           Route the DDL through ServiceRadar.ColdTier.RetentionFence
           (reconcile_policy/3 removes rather than arms policies on
           cold-configured deployments, and safe_drop_point/3 bounds drops by
           verified exports). A direct policy lets the TimescaleDB background
           worker drop chunks that were never exported.
           """
  end

  defp arms_registry_retention?(path) do
    source = File.read!(path)

    arms_policy? =
      String.contains?(source, "add_retention_policy") or String.contains?(source, "drop_chunks")

    fenced? = String.contains?(source, "RetentionFence")

    touches_registry? =
      Enum.any?(Registry.table_names(), fn table ->
        # A CAGG named after its source (e.g. timeseries_metrics_hourly) is a
        # different relation with its own retention — only the raw table
        # matters here.
        Regex.match?(~r/["'](platform\.)?#{Regex.escape(table)}["'\s,)]/, source)
      end)

    arms_policy? and touches_registry? and not fenced?
  end
end
