defmodule ServiceRadarWebNGWeb.DeviceLive.ICMPDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityData
  alias ServiceRadarWebNGWeb.DeviceLive.ICMPData

  @moduletag :db_free
  @scope %{permissions: MapSet.new(["observability.metrics.view"])}
  @opts [time_range: "last_1h", bucket: "5m", aggregate: :avg, limit: 40]
  @host_alpha "sr:host-alpha"
  @host_bravo "sr:host-bravo"

  test "dedicated latency is preferred and canonical sub-millisecond values become milliseconds" do
    respond_with([rows([point(@host_alpha, 250_000)])])

    assert {:ok, [%{"value" => 0.25}]} = load([@host_alpha])
    assert_receive {:icmp_query, query, %{scope: @scope}}
    assert query =~ "metric_type:icmp metric_name:icmp_response_time_ns"
    assert query =~ "time:last_1h bucket:5m agg:avg series:uid"
    refute_receive {:icmp_query, _, _}
  end

  test "sweep latency fills only devices with no dedicated latency samples" do
    respond_with([
      rows([point(@host_alpha, 500_000)]),
      rows([point(@host_bravo, 750_000)])
    ])

    assert {:ok, result} = load([@host_alpha, @host_bravo])

    assert Enum.map(result, &{&1["series"], &1["value"]}) == [
             {@host_alpha, 0.5},
             {@host_bravo, 0.75}
           ]

    assert_receive {:icmp_query, _dedicated, _}
    assert_receive {:icmp_query, sweep, _}
    assert sweep =~ "metric_type:sweep metric_name:sweep.host.icmp_response_time_ns"
    assert sweep =~ ~s[uid:("#{@host_bravo}")]
    refute sweep =~ @host_alpha
    refute_receive {:icmp_query, _, _}
  end

  test "legacy ICMP rows remain supported without mixing modern loss or availability metrics" do
    respond_with([
      rows([]),
      rows([]),
      rows([point(@host_alpha, 1.25), point(@host_alpha, 2_000_000)])
    ])

    assert {:ok, result} = load([@host_alpha])
    assert Enum.map(result, & &1["value"]) == [1.25, 2.0]
    assert_receive {:icmp_query, _dedicated, _}
    assert_receive {:icmp_query, _sweep, _}
    assert_receive {:icmp_query, legacy, _}

    assert legacy =~
             ~s(!metric_name:["icmp_response_time_ns","icmp_packet_loss","icmp_available"])
  end

  test "one source per device prevents duplicates when later responses contain earlier devices" do
    respond_with([
      rows([point(@host_alpha, 500_000)]),
      rows([point(@host_alpha, 900_000), point(@host_bravo, 750_000)])
    ])

    assert {:ok, result} = load([@host_alpha, @host_bravo])

    assert Enum.map(result, &{&1["series"], &1["value"]}) == [
             {@host_alpha, 0.5},
             {@host_bravo, 0.75}
           ]
  end

  test "availability selects authoritative status gauges without scaling their values" do
    respond_with([rows([]), rows([point(@host_alpha, 1)])])

    assert %{total_checks: 1, online_checks: 1, uptime_pct: 100.0} =
             AvailabilityData.load_availability(__MODULE__, @host_alpha, @scope, now: ~U[1999-06-16 00:00:00Z])

    assert_receive {:icmp_query, dedicated, _}
    assert_receive {:icmp_query, sweep, _}
    assert dedicated =~ "metric_name:icmp_available"
    assert dedicated =~ "time:[1999-06-15T00:00:00Z,1999-06-16T00:00:00Z] bucket:30m agg:max"
    assert sweep =~ "metric_name:sweep.host.icmp_available"
    assert sweep =~ "bucket:30m agg:max"
    assert sweep =~ "limit:100"
    refute_receive {:icmp_query, _, _}
  end

  test "selected canonical agent scopes both producers before aggregating failures" do
    respond_with([rows([point(@host_alpha, 1)]), rows([point(@host_alpha, 0)])])

    assert {:ok, [%{"value" => 1}]} =
             ICMPData.load_availability(
               __MODULE__,
               [@host_alpha],
               @scope,
               Keyword.put(@opts, :agent_id, "agent-north")
             )

    for _source <- 1..2 do
      assert_receive {:icmp_query, query, _}
      assert query =~ ~s(agent_id:"agent-north")
      assert query =~ "agg:min"
    end
  end

  test "unselected observers use available-wins instead of poisoning a bucket with another agent's failure" do
    respond_with([rows([point(@host_alpha, 0), point(@host_alpha, 1)]), rows([])])

    assert {:ok, [%{"value" => 1}]} =
             ICMPData.load_availability(__MODULE__, [@host_alpha], @scope, @opts)

    for _source <- 1..2 do
      assert_receive {:icmp_query, query, _}
      assert query =~ "agg:max"
      refute query =~ "agent_id:"
    end
  end

  test "query errors remain errors and do not trigger another metrics scan" do
    respond_with([{:error, :query_unavailable}])

    assert {:error, :query_unavailable} = load([@host_alpha])
    assert_receive {:icmp_query, _, _}
    refute_receive {:icmp_query, _, _}
  end

  test "unexpected responses fail explicitly" do
    respond_with([{:ok, %{}}])
    assert {:error, :invalid_icmp_metrics_response} = load([@host_alpha])
  end

  test "invalid numeric rows are ignored and empty sources remain empty" do
    respond_with([rows([point(@host_alpha, "invalid")]), rows([]), rows([])])
    assert {:ok, []} = load([@host_alpha])
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
    %{"series" => uid, "value" => value, "timestamp" => "1999-06-15T00:00:00Z"}
  end
end
