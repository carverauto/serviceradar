defmodule ServiceRadar.Observability.HourlyRollupRetentionDbTest do
  @moduledoc """
  `DataRetentionWorker.reconcile_hourly_rollups/1` against the real hourly
  continuous aggregates. Serial because it alters shared views; the sandbox
  transaction rolls the DDL back.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.DataRetentionWorker
  alias ServiceRadar.Repo

  @moduletag :integration

  @rollups ~w(
    cpu_metrics_hourly
    memory_metrics_hourly
    disk_metrics_hourly
    process_metrics_hourly
    timeseries_metrics_hourly
    timeseries_metrics_disk_hourly
    timeseries_metrics_interface_hourly
  )

  setup do
    # The worker skips absent views, so without this every assertion below
    # could pass against a schema that has none of them.
    assert present_rollups() == Enum.sort(@rollups)
    :ok
  end

  test "applies the configured retention, a one-day chunk interval and compression" do
    log =
      capture_log(fn ->
        assert :ok =
                 DataRetentionWorker.reconcile_hourly_rollups(hourly_rollup_retention_days: 30)
      end)

    refute log =~ "Failed to reconcile hourly rollup"

    for view <- @rollups do
      assert %{
               drop_after: "30 days",
               chunk_interval: "1 day",
               compression_enabled: true,
               compress_after: "7 days"
             } = rollup_state(view),
             view
    end
  end

  test "floors retention at seven days" do
    assert :ok = DataRetentionWorker.reconcile_hourly_rollups(hourly_rollup_retention_days: 2)

    for view <- @rollups do
      assert %{drop_after: "7 days"} = rollup_state(view), view
    end
  end

  test "keeps an unchanged retention policy instead of re-registering it" do
    DataRetentionWorker.reconcile_hourly_rollups(hourly_rollup_retention_days: 30)
    first = Map.new(@rollups, &{&1, rollup_state(&1).retention_job_id})

    DataRetentionWorker.reconcile_hourly_rollups(hourly_rollup_retention_days: 30)
    second = Map.new(@rollups, &{&1, rollup_state(&1).retention_job_id})

    assert first == second
    refute Enum.any?(Map.values(first), &is_nil/1)
  end

  defp present_rollups do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT view_name
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform' AND view_name = ANY($1)
        ORDER BY view_name
        """,
        [@rollups]
      )

    List.flatten(rows)
  end

  defp rollup_state(view) do
    %{rows: [[compression_enabled, chunk_interval, drop_after, retention_job_id, compress_after]]} =
      SQL.query!(
        Repo,
        """
        SELECT ca.compression_enabled,
               d.time_interval::text,
               retention.config->>'drop_after',
               retention.job_id,
               compression.config->>'compress_after'
        FROM timescaledb_information.continuous_aggregates ca
        JOIN timescaledb_information.dimensions d
          ON d.hypertable_schema = ca.materialization_hypertable_schema
         AND d.hypertable_name = ca.materialization_hypertable_name
        LEFT JOIN timescaledb_information.jobs retention
          ON retention.proc_name = 'policy_retention'
         AND retention.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
         AND retention.hypertable_name IN (ca.view_name, ca.materialization_hypertable_name)
        LEFT JOIN timescaledb_information.jobs compression
          ON compression.proc_name = 'policy_compression'
         AND compression.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
         AND compression.hypertable_name IN (ca.view_name, ca.materialization_hypertable_name)
        WHERE ca.view_schema = 'platform' AND ca.view_name = $1
        """,
        [view]
      )

    %{
      compression_enabled: compression_enabled,
      chunk_interval: chunk_interval,
      drop_after: drop_after,
      retention_job_id: retention_job_id,
      compress_after: compress_after
    }
  end
end
