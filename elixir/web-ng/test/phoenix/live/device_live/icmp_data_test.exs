defmodule ServiceRadarWebNGWeb.DeviceLive.ICMPDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityData
  alias ServiceRadarWebNGWeb.DeviceLive.ICMPData

  @moduletag :db_free
  @scope %{permissions: MapSet.new(["observability.metrics.view"])}
  @opts [time_range: "last_1h", bucket: "5m", aggregate: :avg, limit: 40]

  test "dedicated latency is preferred and canonical sub-millisecond values become milliseconds" do
    respond_with([rows([point("sr:device-a", 250_000)])])

    assert {:ok, [%{"value" => 0.25}]} = load(["sr:device-a"])
    assert_receive {:icmp_query, query, %{scope: @scope}}
    assert query =~ "metric_type:icmp metric_name:icmp_response_time_ns"
    assert query =~ "time:last_1h bucket:5m agg:avg series:uid"
    refute_receive {:icmp_query, _, _}
  end

  test "sweep latency fills only devices with no dedicated latency samples" do
    respond_with([
      rows([point("sr:device-a", 500_000)]),
      rows([point("sr:device-b", 750_000)])
    ])

    assert {:ok, result} = load(["sr:device-a", "sr:device-b"])

    assert Enum.map(result, &{&1["series"], &1["value"]}) == [
             {"sr:device-a", 0.5},
             {"sr:device-b", 0.75}
           ]

    assert_receive {:icmp_query, _dedicated, _}
    assert_receive {:icmp_query, sweep, _}
    assert sweep =~ "metric_type:sweep metric_name:sweep.host.icmp_response_time_ns"
    assert sweep =~ ~s[uid:("sr:device-b")]
    refute sweep =~ "sr:device-a"
    refute_receive {:icmp_query, _, _}
  end

  test "legacy ICMP rows remain supported without mixing modern loss or availability metrics" do
    respond_with([
      rows([]),
      rows([]),
      rows([point("sr:device-a", 1.25), point("sr:device-a", 2_000_000)])
    ])

    assert {:ok, result} = load(["sr:device-a"])
    assert Enum.map(result, & &1["value"]) == [1.25, 2.0]
    assert_receive {:icmp_query, _dedicated, _}
    assert_receive {:icmp_query, _sweep, _}
    assert_receive {:icmp_query, legacy, _}

    assert legacy =~
             ~s(!metric_name:["icmp_response_time_ns","icmp_packet_loss","icmp_available"])
  end

  test "one source per device prevents duplicates when later responses contain earlier devices" do
    respond_with([
      rows([point("sr:device-a", 500_000)]),
      rows([point("sr:device-a", 900_000), point("sr:device-b", 750_000)])
    ])

    assert {:ok, result} = load(["sr:device-a", "sr:device-b"])

    assert Enum.map(result, &{&1["series"], &1["value"]}) == [
             {"sr:device-a", 0.5},
             {"sr:device-b", 0.75}
           ]
  end

  test "availability uses the same source selection without scaling bucket counts" do
    respond_with([rows([]), rows([point("sr:device-a", 3)])])

    assert %{total_checks: 1, online_checks: 1, uptime_pct: 100.0} =
             AvailabilityData.load_availability(__MODULE__, "sr:device-a", @scope)

    assert_receive {:icmp_query, dedicated, _}
    assert_receive {:icmp_query, sweep, _}
    assert dedicated =~ "time:last_6h bucket:30m agg:count"
    assert sweep =~ "time:last_6h bucket:30m agg:count"
    assert sweep =~ "limit:100"
    refute_receive {:icmp_query, _, _}
  end

  test "query errors remain errors and do not trigger another metrics scan" do
    respond_with([{:error, :analytics_head_unavailable}])

    assert {:error, :analytics_head_unavailable} = load(["sr:device-a"])
    assert_receive {:icmp_query, _, _}
    refute_receive {:icmp_query, _, _}
  end

  test "unexpected responses fail explicitly" do
    respond_with([{:ok, %{}}])
    assert {:error, :invalid_icmp_metrics_response} = load(["sr:device-a"])
  end

  test "invalid numeric rows are ignored and empty sources remain empty" do
    respond_with([rows([point("sr:device-a", "invalid")]), rows([]), rows([])])
    assert {:ok, []} = load(["sr:device-a"])
  end

  test "no requested devices performs no queries" do
    assert {:ok, []} = load([])
    refute_receive {:icmp_query, _, _}
  end

  def query(query, opts) do
    send(self(), {:icmp_query, query, opts})
    [response | remaining] = Process.get(:icmp_responses, [])
    Process.put(:icmp_responses, remaining)
    response
  end

  defp load(uids), do: ICMPData.load(__MODULE__, uids, @scope, @opts)
  defp respond_with(responses), do: Process.put(:icmp_responses, responses)
  defp rows(points), do: {:ok, %{"results" => points}}

  defp point(uid, value) do
    %{"series" => uid, "value" => value, "timestamp" => "2000-01-01T00:00:00Z"}
  end
end
