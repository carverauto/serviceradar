defmodule ServiceRadarWebNGWeb.DashboardLive.MtrWarehouseRoutingTest do
  # Not async: the StarRocks switch and its query seam are global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Data.Mtr
  alias ServiceRadarWebNGWeb.DashboardLive.Data.ServiceSparklines

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
    configure(
      prev,
      true,
      recording_mysql(fn _sql -> {:ok, %{columns: [], rows: [[3, 2, 2, 2, Decimal.new("50.0"), 20.0, 2]]}} end)
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

    assert {:ok, %{rows: []}} = ServiceSparklines.warehouse_mtr_sparkline_rows(@cutoff, 900, :loss_pct)
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
