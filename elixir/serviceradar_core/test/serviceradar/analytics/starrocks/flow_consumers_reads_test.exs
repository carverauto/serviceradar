defmodule ServiceRadar.Analytics.StarRocks.FlowConsumersReadsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.FlowConsumers

  @moduletag :db_free

  @cutoff ~U[2025-01-01 00:00:00Z]
  @now ~U[2025-01-02 12:00:00Z]
  @early ~U[2025-01-01 06:00:00Z]

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  defp recording(rows) do
    parent = self()

    fn sql ->
      send(parent, {:sql, sql})
      {:ok, %{rows: rows}}
    end
  end

  # Answers the two freshness probes with the given high-water marks and
  # records every other statement.
  defp recording_with_marks(raw_max, mv_max, rows) do
    parent = self()

    fn
      "SELECT MAX(`time`) FROM serviceradar.ocsf_network_activity" ->
        mark(raw_max)

      "SELECT MAX(`bucket`) FROM serviceradar.ocsf_network_activity_hourly" ->
        mark(mv_max)

      sql ->
        send(parent, {:sql, sql})
        {:ok, %{rows: rows}}
    end
  end

  defp mark({:error, _reason} = error), do: error
  defp mark(value), do: {:ok, %{rows: [[value]]}}

  test "cut_over?/0 follows the flows dataset, not StarRocks being enabled", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    refute FlowConsumers.cut_over?()

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    assert FlowConsumers.cut_over?()
  end

  test "a whole-hour bucket reads the hourly rollup while it is fresh, oldest bucket first" do
    query =
      recording_with_marks(~N[2025-01-02 10:20:00], ~N[2025-01-02 10:00:00], [[:b, 1, 2, 3]])

    assert {:ok, [[:b, 1, 2, 3]]} =
             FlowConsumers.traffic_rows(@cutoff, 21_600, 96, query: query, now: @now)

    assert_received {:sql, sql}

    assert sql =~
             "FROM serviceradar.ocsf_network_activity_hourly WHERE bucket >= '2025-01-01T00:00:00Z'"

    assert sql =~ "time_slice(bucket, INTERVAL 21600 SECOND)"
    assert sql =~ "SUM(bytes_total) AS bytes_total"
    assert sql =~ "ORDER BY 1 DESC LIMIT 96) recent ORDER BY bucket ASC"
    refute sql =~ "sampling_rate"
  end

  test "a stale rollup reads the raw table over the same bucket and window" do
    query = recording_with_marks(~N[2025-01-02 10:20:00], ~N[2024-12-30 00:00:00], [])

    assert {:ok, []} = FlowConsumers.traffic_rows(@cutoff, 21_600, 96, query: query, now: @now)

    assert_received {:sql, sql}
    assert sql =~ "FROM serviceradar.ocsf_network_activity WHERE `time` >= '2025-01-01T00:00:00Z'"
    refute sql =~ "_hourly"
    assert sql =~ "time_slice(`time`, INTERVAL 21600 SECOND)"
    assert sql =~ "* GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_total"
  end

  test "a rollup whose freshness cannot be probed reads the raw table" do
    for {raw_max, mv_max} <- [
          {{:error, :starrocks_mysql_not_started}, ~N[2025-01-02 10:00:00]},
          {~N[2025-01-02 10:20:00], {:error, :unknown_table}},
          {~N[2025-01-02 10:20:00], nil}
        ] do
      query = recording_with_marks(raw_max, mv_max, [])

      assert {:ok, []} = FlowConsumers.traffic_rows(@cutoff, 3_600, 96, query: query, now: @now)

      assert_received {:sql, sql}
      assert sql =~ "FROM serviceradar.ocsf_network_activity WHERE `time` >="
      refute sql =~ "_hourly"
    end
  end

  test "the scan starts no earlier than the buckets that can be drawn" do
    now = ~U[2025-04-01 12:07:30Z]
    cutoff = DateTime.add(now, -90, :day)

    assert {:ok, []} =
             FlowConsumers.traffic_rows(cutoff, 900, 96, query: recording([]), now: now)

    assert_received {:sql, raw_sql}
    assert raw_sql =~ "WHERE `time` >= '2025-03-31T12:00:00Z'"

    query = recording_with_marks(~N[2025-04-01 12:05:00], ~N[2025-04-01 12:00:00], [])
    assert {:ok, []} = FlowConsumers.traffic_rows(cutoff, 3_600, 96, query: query, now: now)

    assert_received {:sql, rollup_sql}
    assert rollup_sql =~ "ocsf_network_activity_hourly WHERE bucket >= '2025-03-28T12:00:00Z'"
  end

  test "a cutoff newer than the drawable span still bounds the scan" do
    cutoff = ~U[2025-01-02 11:10:20Z]

    assert {:ok, []} =
             FlowConsumers.traffic_rows(cutoff, 900, 96, query: recording([]), now: @now)

    assert_received {:sql, sql}
    assert sql =~ "WHERE `time` >= '2025-01-02T11:00:00Z'"
  end

  test "a finer bucket reads the raw table with the rollup's sampling weighting" do
    assert {:ok, []} =
             FlowConsumers.traffic_rows(@cutoff, 900, 96, query: recording([]), now: @early)

    assert_received {:sql, sql}
    assert sql =~ "FROM serviceradar.ocsf_network_activity WHERE `time` >= '2025-01-01T00:00:00Z'"
    refute sql =~ "_hourly"
    assert sql =~ "* GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_total"
    assert sql =~ "COUNT(*) AS flow_count"
  end

  test "the address probes match either end, or the exporter, within the window" do
    assert {:ok, true} =
             FlowConsumers.seen_for_ip?("192.0.2.10", @cutoff, query: recording([[1]]))

    assert_received {:sql, sql}
    assert sql =~ "(src_endpoint_ip = '192.0.2.10' OR dst_endpoint_ip = '192.0.2.10')"
    assert sql =~ "`time` >= '2025-01-01T00:00:00Z'"
    assert sql =~ "LIMIT 1"

    assert {:ok, false} =
             FlowConsumers.seen_for_sampler?("2001:db8::1", @cutoff, query: recording([]))

    assert_received {:sql, sql}
    assert sql =~ "sampler_address = '2001:db8::1'"
  end

  test "anything that is not an address matches no flow and never reaches the warehouse" do
    never = fn _sql -> flunk("a value that is not an address was sent to the warehouse") end

    for value <- ["192.0.2.10' OR '1'='1", "host01.example.com", "", "192.0.2.0/24", nil, 42] do
      assert {:ok, false} = FlowConsumers.seen_for_ip?(value, @cutoff, query: never)
      assert {:ok, false} = FlowConsumers.seen_for_sampler?(value, @cutoff, query: never)
    end
  end

  test "a warehouse error is returned, not swallowed" do
    failing = fn _sql -> {:error, :starrocks_mysql_not_started} end

    assert {:error, :starrocks_mysql_not_started} =
             FlowConsumers.traffic_rows(@cutoff, 900, 96, query: failing)

    assert {:error, :starrocks_mysql_not_started} =
             FlowConsumers.seen_for_ip?("192.0.2.10", @cutoff, query: failing)
  end
end
