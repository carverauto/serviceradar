defmodule ServiceRadarWebNGWeb.DashboardLive.MtrWarehouseRoutingTest do
  # Not async: the StarRocks switch and its query seam are global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Data.Mtr
  alias ServiceRadarWebNGWeb.DashboardLive.Data.ServiceSparklines
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse

  @moduletag :db_free

  @cutoff ~U[2026-01-01 00:00:00Z]

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  # `:mysql` is StarRocks.Query's own seam: every warehouse statement the
  # dashboard sends reaches this function instead of a Frontend.
  defp configure(prev, enabled?, mysql) do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, enabled?)
      |> Keyword.put(:cutover_datasets, [])
      |> Keyword.put(:mysql, mysql)
    )
  end

  defp recording_mysql(answer) do
    test = self()

    fn sql ->
      send(test, {:warehouse, sql})
      answer.(sql)
    end
  end

  # Answers the destination-rollup freshness probes with the given high-water
  # marks and records every other statement, as the flows readers' tests do.
  defp recording_with_marks(raw_max, mv_max, rows) do
    test = self()

    fn
      "SELECT MAX(`time`) FROM serviceradar.mtr_traces" ->
        mark(raw_max)

      "SELECT MAX(`bucket`) FROM serviceradar.mtr_destination_hourly" ->
        mark(mv_max)

      sql ->
        send(test, {:warehouse, sql})
        {:ok, %{rows: rows}}
    end
  end

  defp mark({:error, _reason} = error), do: error
  defp mark(value), do: {:ok, %{rows: [[value]]}}

  test "with StarRocks disabled the MTR card and sparklines keep their CNPG queries", %{prev: prev} do
    configure(prev, false, recording_mysql(fn _sql -> {:error, :warehouse_must_not_be_queried} end))

    assert Mtr.warehouse_summary_rows(@cutoff) == :cnpg
    assert ServiceSparklines.warehouse_mtr_sparkline_rows(@cutoff, 900, :latency_ms) == :cnpg
    assert ServiceSparklines.warehouse_mtr_sparkline_rows(@cutoff, 900, :loss_pct) == :cnpg

    # No database runs under this test, so the CNPG path fails into the empty
    # card; what matters is that the warehouse was never asked.
    assert %{mtr_timeseries: %{path_count: 0}} = Data.load_mtr("last_1h")
    refute_received {:warehouse, _sql}
  end

  test "with StarRocks enabled the MTR card reads the warehouse and shapes its row", %{prev: prev} do
    # The destination rollup reports itself hours behind, so the card takes the
    # raw path this test asserts; the rollup path has its own test below.
    configure(
      prev,
      true,
      recording_with_marks(
        ~N[2026-01-02 12:40:00],
        ~N[2026-01-02 06:00:00],
        [[3, 2, 2, 2, Decimal.new("50.0"), 20.0, 2]]
      )
    )

    assert %{mtr_timeseries: summary} = Data.load_mtr("last_1h")

    assert summary == %{
             path_count: 3,
             endpoint_sample_count: 2,
             loss_sample_count: 2,
             latency_sample_count: 2,
             avg_latency_ms: 20.0,
             avg_loss_pct: 50.0,
             degraded_count: 2
           }

    assert_received {:warehouse, sql}
    refute_received {:warehouse, _another}

    assert sql =~ "FROM serviceradar.mtr_traces"
    assert sql =~ "FROM serviceradar.mtr_hops h"
    refute sql =~ "platform."
    refute sql =~ "FILTER ("
    refute sql =~ "::"
    # The cutoff bounds traces and hops alike, and a hop is never older than its trace.
    assert length(Regex.scan(~r/`time` >= '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}'/, sql)) == 2
    assert sql =~ "AND h.`time` >= st.`time`"
    assert sql =~ "COUNT(CASE WHEN dh.sent > 0 THEN dh.trace_id END) AS loss_sample_count"

    assert sql =~
             "100.0 * CAST(SUM(CASE WHEN dh.sent > 0 THEN dh.sent END) - " <>
               "SUM(CASE WHEN dh.sent > 0 THEN dh.received END) AS DOUBLE) / " <>
               "NULLIF(CAST(SUM(CASE WHEN dh.sent > 0 THEN dh.sent END) AS DOUBLE), 0) AS avg_loss_pct"

    assert sql =~ "CAST(dh.avg_us AS BIGINT) * dh.received"
  end

  test "the MTR card reads the destination rollup while it is fresh", %{prev: prev} do
    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-02 12:40:00], ~N[2026-01-02 12:00:00], [[7, 6, 6, 5, 12.5, 49.5, 2]])
    )

    cutoff = ~U[2026-01-01 13:20:00Z]

    assert {:ok, %{rows: [[7, 6, 6, 5, 12.5, 49.5, 2]]}} = MtrWarehouse.dashboard_summary(cutoff)

    assert_received {:warehouse, sql}
    refute_received {:warehouse, _another}

    assert sql =~ "FROM serviceradar.mtr_destination_hourly"
    assert sql =~ "SUM(path_count) AS path_count"
    assert sql =~ "SUM(degraded_count) AS degraded_count"

    assert sql =~
             "100.0 * CAST(SUM(sent_total) - SUM(received_total) AS DOUBLE) / " <>
               "NULLIF(CAST(SUM(sent_total) AS DOUBLE), 0) AS avg_loss_pct"

    assert sql =~
             "CAST(SUM(avg_us_weighted) AS DOUBLE) / " <>
               "NULLIF(CAST(SUM(latency_weight) AS DOUBLE), 0) / 1000.0 AS avg_latency_ms"

    # The lower edge is floored to the hour, and the day bound prunes partitions.
    assert sql =~ "WHERE `bucket` >= '2026-01-01 13:00:00'"
    assert sql =~ "AND `day` >= '2026-01-01 00:00:00'"
    refute sql =~ "ROW_NUMBER"
  end

  test "a whole-hour sparkline reads the destination rollup while it is fresh", %{prev: prev} do
    rows = [[~N[2026-01-01 12:00:00], 12.5], [~N[2026-01-01 13:00:00], 14.0]]

    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-02 12:40:00], ~N[2026-01-02 12:00:00], rows)
    )

    assert {:ok, _} =
             MtrWarehouse.destination_sparkline(~U[2026-01-01 11:30:00Z], 3_600, :loss_pct, 96,
               now: ~U[2026-01-02 12:00:00Z]
             )

    assert_received {:warehouse, sql}
    assert sql =~ "FROM serviceradar.mtr_destination_hourly"
    assert sql =~ "time_slice(`bucket`, INTERVAL 3600 SECOND) AS bucket"
    assert sql =~ "HAVING SUM(sent_total) > 0"
    assert sql =~ "WHERE `bucket` >= '2026-01-01 11:00:00'"
  end

  test "the latency sparkline over the rollup weighs by the stored latency weight", %{prev: prev} do
    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-02 12:40:00], ~N[2026-01-02 12:00:00], [])
    )

    assert {:ok, _} =
             MtrWarehouse.destination_sparkline(~U[2026-01-01 00:00:00Z], 3_600, :latency_ms, 96,
               now: ~U[2026-01-02 12:00:00Z]
             )

    assert_received {:warehouse, sql}
    assert sql =~ "HAVING SUM(latency_weight) > 0"
    refute sql =~ "destination_hops"
  end

  test "a stale destination rollup reads the raw tables for the same window", %{prev: prev} do
    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-02 12:40:00], ~N[2026-01-02 06:00:00], [[3, 2, 2, 2, 12.5, 49.5, 1]])
    )

    cutoff = ~U[2026-01-01 13:20:00Z]
    assert {:ok, _} = MtrWarehouse.dashboard_summary(cutoff)

    assert_received {:warehouse, sql}
    assert sql =~ "FROM serviceradar.mtr_traces"
    assert sql =~ "ROW_NUMBER"
    # The raw fallback reads the same hour-floored lower edge the rollup would.
    assert sql =~ "WHERE `time` >= '2026-01-01 13:00:00'"
    refute sql =~ "mtr_destination_hourly"
  end

  test "a whole-hour sparkline keeps in-range history past the point limit", %{prev: prev} do
    cutoff = ~U[2026-01-01 12:07:00Z]
    now = ~U[2026-01-08 12:07:00Z]

    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-08 12:40:00], ~N[2026-01-08 12:00:00], [])
    )

    assert {:ok, _} =
             MtrWarehouse.destination_sparkline(cutoff, 3_600, :loss_pct, 96, now: now)

    assert_received {:warehouse, sql}
    assert sql =~ "WHERE `bucket` >= '2026-01-01 12:00:00'"
    refute sql =~ "2026-01-04"

    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-08 12:40:00], ~N[2026-01-08 06:00:00], [])
    )

    assert {:ok, _} =
             MtrWarehouse.destination_sparkline(cutoff, 3_600, :loss_pct, 96, now: now)

    assert_received {:warehouse, sql}
    assert sql =~ "t.`time` >= '2026-01-01 12:00:00'"
    refute sql =~ "2026-01-04"

    # last_30d is 6h. Floor to the hour, not back to the 6h bucket.
    cutoff_6h = ~U[2026-01-01 14:07:00Z]

    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-31 14:40:00], ~N[2026-01-31 14:00:00], [])
    )

    assert {:ok, _} = MtrWarehouse.destination_sparkline(cutoff_6h, 21_600, :loss_pct, 96)

    assert_received {:warehouse, sql}
    assert sql =~ "WHERE `bucket` >= '2026-01-01 14:00:00'"
    refute sql =~ "`bucket` >= '2026-01-01 12:00:00'"

    configure(
      prev,
      true,
      recording_with_marks(~N[2026-01-31 14:40:00], ~N[2026-01-31 06:00:00], [])
    )

    assert {:ok, _} = MtrWarehouse.destination_sparkline(cutoff_6h, 21_600, :loss_pct, 96)

    assert_received {:warehouse, sql}
    assert sql =~ "t.`time` >= '2026-01-01 14:00:00'"
    refute sql =~ "2026-01-01 12:00:00"

    # last_90d is one day. Floor to the hour, not back to UTC midnight.
    configure(
      prev,
      true,
      recording_with_marks(~N[2026-04-01 14:40:00], ~N[2026-04-01 14:00:00], [])
    )

    assert {:ok, _} = MtrWarehouse.destination_sparkline(cutoff_6h, 86_400, :loss_pct, 96)

    assert_received {:warehouse, sql}
    assert sql =~ "WHERE `bucket` >= '2026-01-01 14:00:00'"
    refute sql =~ "`bucket` >= '2026-01-01 00:00:00'"
  end

  test "a sub-hour sparkline starts at the cutoff", %{prev: prev} do
    configure(prev, true, recording_mysql(fn _sql -> {:ok, %{columns: ["bucket", "value"], rows: []}} end))

    cutoff = ~U[2026-01-01 12:07:30Z]
    now = ~U[2026-01-02 12:07:30Z]

    for bucket <- [60, 300, 900] do
      assert {:ok, _} = MtrWarehouse.destination_sparkline(cutoff, bucket, :loss_pct, 96, now: now)

      assert_received {:warehouse, sql}
      assert sql =~ "t.`time` >= '2026-01-01 12:07:30'", "bucket #{bucket} floored the cutoff: #{sql}"
    end
  end

  test "the MTR retention reports the warehouse's dataset TTL when enabled", %{prev: prev} do
    configure(prev, true, recording_mysql(fn _sql -> flunk("retention asks no query") end))

    # The real `{table, days}` list. 180 is not the 365 default, so a missed
    # lookup cannot pass by falling through to `Env.default_retention_days`.
    days = StarRocks.Retention.days_by_table(retention_days: [mtr: 180])

    status = MtrWarehouse.retention_status(days_by_table: days)
    assert status.configured_days == 180
    assert status.status == :ok

    assert status.tables == %{
             "mtr_traces" => %{status: :ok, days: 180},
             "mtr_hops" => %{status: :ok, days: 180}
           }

    assert status.backend == :starrocks

    # MtrData routes here, and keeps the CNPG policy when the warehouse is off.
    assert MtrData.retention_status(nil, days_by_table: days) == status
  end

  test "MtrData.retention_status keeps the CNPG policy path when the warehouse is disabled", %{prev: prev} do
    configure(prev, false, recording_mysql(fn _sql -> flunk("a disabled warehouse is never asked") end))

    # No database runs under this test, so the CNPG policy read fails into its
    # degraded shape; what matters is that it is the CNPG path, not a warehouse
    # answer dressed as one.
    status = MtrData.retention_status(nil)
    assert status.status == :degraded
    assert is_map(status.tables) and status.tables == %{}
    refute Map.has_key?(status, :backend)
  end

  test "a warehouse failure leaves the card empty rather than reading CNPG", %{prev: prev} do
    configure(prev, true, recording_mysql(fn _sql -> {:error, :connect_failed} end))

    assert %{mtr_timeseries: %{path_count: 0}} = Data.load_mtr("last_1h")
    assert_received {:warehouse, _sql}
  end

  test "with StarRocks enabled the latency and loss sparklines read the warehouse", %{prev: prev} do
    configure(
      prev,
      true,
      recording_mysql(fn sql ->
        if sql =~ "mtr_hops" do
          {:ok, %{columns: ["bucket", "value"], rows: [["2026-01-01 00:00:00", 20.0], ["2026-01-01 00:01:00", 30.0]]}}
        else
          {:error, :not_an_mtr_statement}
        end
      end)
    )

    assert %{sparklines: sparklines} = Data.load_sparklines("last_1h")
    assert sparklines.latency == [20.0, 30.0]
    assert sparklines.packet_loss == [20.0, 30.0]

    mtr_sql = collect_mtr_sql()
    assert length(mtr_sql) == 2
    [latency_sql] = Enum.filter(mtr_sql, &(&1 =~ "/ 1000.0"))
    [loss_sql] = Enum.reject(mtr_sql, &(&1 =~ "/ 1000.0"))

    for sql <- mtr_sql do
      # last_1h buckets by the minute; time_slice aligns it to midnight UTC as time_bucket does.
      assert sql =~ "time_slice(h.trace_time, INTERVAL 60 SECOND) AS bucket"
      assert sql =~ "LIMIT 96"
      assert sql =~ "AND h.`time` >= t.`time`"
      refute sql =~ "time_bucket"
      refute sql =~ "FILTER ("
      refute sql =~ "::"
    end

    assert latency_sql =~ "HAVING SUM(CASE WHEN h.avg_us IS NOT NULL AND h.received > 0 THEN h.received END) > 0"
    assert loss_sql =~ "HAVING SUM(CASE WHEN h.sent > 0 THEN h.sent END) > 0"
  end

  test "the sparkline query takes the cutoff, bucket width and point count it is given", %{prev: prev} do
    configure(prev, true, recording_mysql(fn _sql -> {:ok, %{columns: ["bucket", "value"], rows: []}} end))

    assert {:ok, %{rows: []}} =
             ServiceSparklines.warehouse_mtr_sparkline_rows(@cutoff, 900, :loss_pct, now: ~U[2026-01-01 06:00:00Z])

    assert_received {:warehouse, sql}
    assert sql =~ "WHERE t.`time` >= '2026-01-01 00:00:00'"
    assert sql =~ "AND h.`time` >= '2026-01-01 00:00:00'"
    assert sql =~ "INTERVAL 900 SECOND"
    assert sql =~ "LIMIT 96"
  end

  defp collect_mtr_sql(acc \\ []) do
    receive do
      {:warehouse, sql} ->
        if sql =~ "mtr_hops", do: collect_mtr_sql([sql | acc]), else: collect_mtr_sql(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
