defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityData

  @moduletag :db_free
  @now ~U[2000-01-02 12:15:00Z]
  @scope %{permissions: MapSet.new(["observability.metrics.view"])}

  test "a full day preserves unknown gaps and counts only observed status buckets" do
    respond_with([
      rows([
        point("2000-01-02T12:00:00Z", 1),
        point("2000-01-01T12:00:00Z", 0),
        point("2000-01-02T00:00:00Z", 1)
      ])
    ])

    result = load()
    assert result.window_start == ~U[2000-01-01 12:15:00Z]
    assert result.window_end == @now
    assert result.bucket_count == 49
    assert result.total_checks == 3
    assert result.online_checks == 2
    assert result.offline_checks == 1
    assert result.unknown_checks == 46
    assert result.uptime_pct == 66.7
    assert hd(result.segments).status == :offline
    assert List.last(result.segments).status == :online
    assert Enum.at(result.segments, 1).status == :unknown
    assert Enum.map(result.segments, & &1.timestamp) == Enum.sort(Enum.map(result.segments, & &1.timestamp))
    assert_in_delta Enum.sum(Enum.map(result.segments, & &1.width)), 100.0, 0.00001
    assert_in_delta hd(result.segments).width * 2, Enum.at(result.segments, 1).width, 0.00001

    assert_receive {:query, query, %{scope: @scope}}
    assert query =~ "time:[2000-01-01T12:15:00Z,2000-01-02T12:15:00Z]"
    assert query =~ "metric_name:icmp_available"
    assert query =~ "agg:min"
    assert_receive {:query, sweep, _}
    assert sweep =~ "metric_name:sweep.host.icmp_available"
    refute_receive {:query, _, _}
  end

  test "an observed failure wins within its bucket and is not inferred from missing latency" do
    respond_with([rows([point("2000-01-02T01:00:00Z", 1), point("2000-01-02T01:00:00Z", 0)])])
    assert %{total_checks: 1, offline_checks: 1, online_checks: 0, uptime_pct: percent} = load()
    assert percent == 0.0
  end

  test "missing dedicated observations fall back to sweep status with the same fixed window" do
    respond_with([rows([]), rows([point("2000-01-02T01:00:00Z", "0")])])
    assert %{offline_checks: 1, uptime_pct: percent} = load()
    assert percent == 0.0
    assert_receive {:query, dedicated, _}
    assert_receive {:query, sweep, _}
    assert dedicated =~ "metric_name:icmp_available"
    assert sweep =~ "metric_name:sweep.host.icmp_available"

    assert Enum.find(String.split(dedicated), &String.starts_with?(&1, "time:")) ==
             Enum.find(String.split(sweep), &String.starts_with?(&1, "time:"))

    refute_receive {:query, _, _}
  end

  test "sweep fills gaps in preferred coverage while a preferred failure wins its own bucket" do
    respond_with([
      rows([point("2000-01-01T13:00:00Z", 0), point("2000-01-01T13:30:00Z", 1)]),
      rows([
        point("2000-01-01T14:00:00+01:00", 1),
        point("2000-01-02T11:30:00Z", 1),
        point("2000-01-02T12:00:00Z", 0)
      ])
    ])

    result = load()
    assert result.total_checks == 4
    assert result.online_checks == 2
    assert result.offline_checks == 2
    assert result.uptime_pct == 50.0
    assert Enum.find(result.segments, &(&1.timestamp == "2000-01-01T13:00:00Z")).status == :offline
    assert Enum.find(result.segments, &(&1.timestamp == "2000-01-02T11:30:00Z")).status == :online
    assert List.last(result.segments).status == :offline
  end

  test "no authoritative observations means unknown coverage without a success percentage" do
    respond_with([rows([]), rows([])])
    result = load(now: ~U[2000-01-02 12:00:00Z])
    assert result.bucket_count == 48
    assert result.unknown_checks == 48
    assert result.total_checks == 0
    assert is_nil(result.uptime_pct)
    assert Enum.all?(result.segments, &(&1.status == :unknown))
    assert_receive {:query, _, _}
    assert_receive {:query, _, _}
    refute_receive {:query, _, _}
  end

  test "invalid statuses and timestamps cannot create online or offline observations" do
    respond_with([
      rows([
        point("2000-01-02T01:00:00Z", 2),
        point("not-a-timestamp", 1),
        point("1999-12-31T00:00:00Z", 1),
        point("2000-01-03T00:00:00Z", 0)
      ])
    ])

    assert %{total_checks: 0, uptime_pct: nil, unknown_checks: 49} = load()
  end

  test "a query failure does not become an unknown or healthy result or query an unsupported entity" do
    respond_with([{:error, :query_unavailable}])
    assert is_nil(load())
    assert_receive {:query, _, _}
    refute_receive {:query, _, _}
  end

  def query(query, opts) do
    send(self(), {:query, query, opts})
    [response | remaining] = Process.get(:availability_responses)
    Process.put(:availability_responses, remaining)
    response
  end

  defp load(opts \\ []) do
    AvailabilityData.load_availability(__MODULE__, "sr:synthetic-device", @scope, Keyword.put_new(opts, :now, @now))
  end

  defp respond_with([{:ok, _} = preferred]), do: respond_with([preferred, rows([])])
  defp respond_with(responses), do: Process.put(:availability_responses, responses)
  defp rows(points), do: {:ok, %{"results" => points}}
  defp point(timestamp, value), do: %{"series" => "sr:synthetic-device", "timestamp" => timestamp, "value" => value}
end
