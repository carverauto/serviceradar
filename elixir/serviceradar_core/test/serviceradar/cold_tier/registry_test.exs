defmodule ServiceRadar.ColdTier.RegistryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Registry.Table
  alias ServiceRadar.Observability.DataRetentionWorker

  @known_types [
    "timestamptz",
    "text",
    "integer",
    "bigint",
    "double precision",
    "boolean",
    "uuid",
    "jsonb",
    "text[]"
  ]

  test "v1 registry covers exactly the seven offload tables" do
    assert Enum.sort(Registry.table_names()) ==
             Enum.sort([
               "logs",
               "otel_traces",
               "otel_metrics",
               "otel_metric_points",
               "timeseries_metrics",
               "ocsf_events",
               "ocsf_network_activity"
             ])
  end

  test "every entry is internally consistent" do
    for %Table{} = entry <- Registry.tables() do
      column_names = Enum.map(entry.columns, fn {name, _type, _cast} -> name end)

      assert column_names == Enum.uniq(column_names),
             "#{entry.table}: duplicate columns"

      assert entry.time_column in column_names,
             "#{entry.table}: time column #{entry.time_column} missing from columns"

      for tiebreaker <- entry.tiebreakers do
        assert tiebreaker in column_names,
               "#{entry.table}: tiebreaker #{tiebreaker} missing from columns"
      end

      for {name, type, cast} <- entry.columns do
        assert type in @known_types, "#{entry.table}.#{name}: unknown type #{type}"
        assert cast in [:none, :text], "#{entry.table}.#{name}: unknown cast #{inspect(cast)}"
      end

      # uuid and jsonb must always export as text (canonical casts, design D2/R7)
      for {name, type, cast} <- entry.columns, type in ["uuid", "jsonb"] do
        assert cast == :text, "#{entry.table}.#{name}: #{type} must cast to text"
      end

      assert entry.default_hot_days > 0
      assert entry.default_chunk_hours > 0
    end
  end

  test "ocsf_events is the only update-prone v1 table" do
    update_prone = Registry.tables() |> Enum.filter(& &1.update_prone) |> Enum.map(& &1.table)
    assert update_prone == ["ocsf_events"]
  end

  test "export_select_list applies canonical casts" do
    logs = Registry.fetch!("logs")
    select_list = Registry.export_select_list(logs)

    assert select_list =~ ~s("timestamp")
    assert select_list =~ ~s("id"::text AS "id")
    refute select_list =~ ~s("body"::text)

    events = Registry.fetch!("ocsf_events")
    assert Registry.export_select_list(events) =~ ~s("metadata"::text AS "metadata")
  end

  test "object_prefix is deterministic and versioned" do
    logs = Registry.fetch!("logs")
    assert Registry.object_prefix(logs, ~D[2026-07-01]) == "cold/v1/logs/date=2026-07-01"
  end

  test "hot_retention_days reads the retention worker config with registry defaults" do
    timeseries = Registry.fetch!("timeseries_metrics")
    original = Application.get_env(:serviceradar_core, DataRetentionWorker)

    try do
      Application.delete_env(:serviceradar_core, DataRetentionWorker)
      assert Registry.hot_retention_days(timeseries) == 7

      Application.put_env(:serviceradar_core, DataRetentionWorker,
        timeseries_metrics_retention_days: 21
      )

      assert Registry.hot_retention_days(timeseries) == 21
    after
      if original do
        Application.put_env(
          :serviceradar_core,
          DataRetentionWorker,
          original
        )
      else
        Application.delete_env(:serviceradar_core, DataRetentionWorker)
      end
    end
  end

  test "cold tier is disabled without deployment configuration" do
    original = Application.get_env(:serviceradar_core, ServiceRadar.ColdTier)

    try do
      Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
      refute Registry.enabled?()

      Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, enabled: true)
      refute Registry.enabled?()

      Application.put_env(:serviceradar_core, ServiceRadar.ColdTier,
        enabled: true,
        bucket_url: "s3://tenant-cold"
      )

      assert Registry.enabled?()
      assert Registry.bucket_url() == "s3://tenant-cold"
    after
      if original do
        Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, original)
      else
        Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
      end
    end
  end

  test "cold_window_days is nil without explicit config and honors per-class config" do
    logs = Registry.fetch!("logs")
    original = Application.get_env(:serviceradar_core, ServiceRadar.ColdTier)

    try do
      Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)

      # No default: this value is what the pruner DELETES archives by, so an
      # absent window must mean "no expiry pruning" (design D9), never 365.
      assert Registry.cold_window_days(logs) == nil

      Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cold_windows: [logs: 180])
      assert Registry.cold_window_days(logs) == 180
    after
      if original do
        Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, original)
      else
        Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
      end
    end
  end
end
