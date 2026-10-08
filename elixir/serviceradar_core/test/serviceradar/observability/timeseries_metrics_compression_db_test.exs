defmodule ServiceRadar.Observability.TimeseriesMetricsCompressionDbTest do
  @moduledoc """
  `DataRetentionWorker.reconcile_timeseries_metrics_compression/1` against the
  real raw `timeseries_metrics` hypertable, and proof that the hourly rollup
  still refreshes once a raw chunk inside its refresh window is compressed.

  Serial: the policy cases run Timescale policy DDL that the sandbox rolls
  back, and the refresh case is unboxed because `refresh_continuous_aggregate`
  cannot run inside a transaction.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.DataRetentionWorker
  alias ServiceRadar.Repo

  @moduletag :integration

  @rollup "platform.timeseries_metrics_hourly"

  describe "compression policy" do
    test "re-registers the raw policy at the configured lag" do
      # The migration installs 6 days, so a reconcile that did nothing fails here.
      assert {_job_id, 144.0} = policy()

      log =
        capture_log(fn ->
          assert :ok = reconcile(24)
        end)

      refute log =~ "Failed to reconcile timeseries_metrics compression"
      assert {first_job_id, 24.0} = policy()

      assert :ok = reconcile(36)
      assert {second_job_id, 36.0} = policy()
      refute second_job_id == first_job_id
    end

    test "keeps an unchanged policy instead of re-registering it" do
      assert :ok = reconcile(24)
      {job_id, 24.0} = policy()

      assert :ok = reconcile(24)
      assert {^job_id, 24.0} = policy()
    end

    test "warns when the lag is not shorter than retention" do
      log =
        capture_log(fn ->
          assert :ok =
                   DataRetentionWorker.reconcile_timeseries_metrics_compression(
                     timeseries_metrics_compress_after_hours: 7 * 24,
                     timeseries_metrics_retention_days: 7
                   )
        end)

      assert log =~ "chunks are dropped before they are compressed"
    end
  end

  @tag sandbox: :unboxed
  test "the hourly rollup refreshes over a compressed raw chunk, including a late insert" do
    unique = System.unique_integer([:positive])
    device_id = "sr:compress-refresh-db-#{unique}"
    series_key = "compress-refresh-db:#{device_id}"

    # 01:00 two days back: a closed chunk inside the rollups' 5-day refresh
    # window, with room for three hourly buckets before midnight.
    day = Date.add(Date.utc_today(), -2)
    first_hour = DateTime.new!(day, ~T[01:00:00], "Etc/UTC")
    late_hour = DateTime.shift(first_hour, hour: 2)
    window = {DateTime.shift(first_hour, hour: -1), DateTime.shift(first_hour, hour: 4)}

    insert_sample!(DateTime.shift(first_hour, minute: 5), device_id, series_key, 10.0)
    insert_sample!(DateTime.shift(first_hour, minute: 65), device_id, series_key, 20.0)

    chunk = chunk_containing!(first_hour)
    was_compressed = compressed?(chunk)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.timeseries_metrics WHERE series_key = $1", [series_key])
      refresh!(window)

      if !was_compressed do
        Repo.query!("SELECT decompress_chunk(($1::text)::regclass, if_compressed => true)", [
          chunk
        ])
      end
    end)

    Repo.query!("SELECT compress_chunk(($1::text)::regclass, if_not_compressed => true)", [chunk])
    assert compressed?(chunk)

    insert_sample!(DateTime.shift(late_hour, minute: 5), device_id, series_key, 30.0)
    assert chunk_containing!(late_hour) == chunk, "late sample must land in the compressed chunk"

    assert materialized_buckets(device_id) == []

    refresh!(window)

    assert materialized_buckets(device_id) == [
             {first_hour, 10.0, 1},
             {DateTime.shift(first_hour, hour: 1), 20.0, 1},
             {late_hour, 30.0, 1}
           ]
  end

  defp reconcile(hours) do
    DataRetentionWorker.reconcile_timeseries_metrics_compression(
      timeseries_metrics_compress_after_hours: hours
    )
  end

  defp policy do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT job_id,
               (extract(epoch FROM (config->>'compress_after')::interval) / 3600)::float8
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_compression'
          AND hypertable_schema = 'platform'
          AND hypertable_name = 'timeseries_metrics'
        """,
        []
      )

    case rows do
      [[job_id, hours]] -> {job_id, hours}
      other -> flunk("expected one timeseries_metrics compression policy, got #{inspect(other)}")
    end
  end

  defp insert_sample!(timestamp, device_id, series_key, value) do
    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics (
        "timestamp", gateway_id, agent_id, series_key, device_id,
        metric_type, metric_name, value
      )
      VALUES ($1, 'compress-refresh-db-gateway', 'compress-refresh-db-agent', $2, $3,
              'snmp', 'ifInOctets', $4)
      """,
      [timestamp, series_key, device_id, value]
    )
  end

  defp chunk_containing!(timestamp) do
    %{rows: [[chunk]]} =
      Repo.query!(
        """
        SELECT format('%I.%I', chunk_schema, chunk_name)
        FROM timescaledb_information.chunks
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'timeseries_metrics'
          AND range_start <= $1
          AND range_end > $1
        """,
        [timestamp]
      )

    chunk
  end

  defp compressed?(chunk) do
    %{rows: [[compressed]]} =
      Repo.query!(
        """
        SELECT is_compressed
        FROM timescaledb_information.chunks
        WHERE format('%I.%I', chunk_schema, chunk_name) = $1
        """,
        [chunk]
      )

    compressed
  end

  defp refresh!({start, stop}) do
    Repo.query!(
      "CALL refresh_continuous_aggregate('#{@rollup}', $1::timestamptz, $2::timestamptz)",
      [start, stop]
    )
  end

  # Reads the materialization, not the view: a real-time view would answer
  # from raw rows and pass without any refresh.
  defp materialized_buckets(device_id) do
    %{rows: [[materialization]]} =
      Repo.query!(
        """
        SELECT format('%I.%I', materialization_hypertable_schema, materialization_hypertable_name)
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform' AND view_name = 'timeseries_metrics_hourly'
        """,
        []
      )

    %{rows: rows} =
      Repo.query!(
        "SELECT bucket, avg_value, sample_count FROM #{materialization} WHERE device_id = $1 ORDER BY bucket",
        [device_id]
      )

    Enum.map(rows, fn [bucket, avg_value, sample_count] ->
      {DateTime.truncate(bucket, :second), avg_value, sample_count}
    end)
  end
end
