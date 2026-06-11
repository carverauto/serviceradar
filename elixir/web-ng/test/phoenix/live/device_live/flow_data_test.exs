defmodule ServiceRadarWebNGWeb.DeviceLive.FlowDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.FlowData

  defmodule CapturingSRQL do
    def query(query, opts) do
      send(Process.get(:test_pid), {:srql_query, query, opts})

      {:ok, %{"results" => [], "pagination" => %{"limit" => Map.get(opts, :limit)}}}
    end
  end

  test "load_flows bounds device flow query to the recent window" do
    Process.put(:test_pid, self())

    assert {[], %{"limit" => 50}, nil} =
             FlowData.load_flows(CapturingSRQL, ~s|sr:test"device|, :scope, nil, 50)

    assert_received {:srql_query, query, %{scope: :scope, limit: 50, cursor: nil}}
    assert query == ~s|in:flows device_id:"sr:test\\"device" time:last_24h sort:time:desc|
  end
end
