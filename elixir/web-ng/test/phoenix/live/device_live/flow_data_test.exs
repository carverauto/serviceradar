defmodule ServiceRadarWebNGWeb.DeviceLive.FlowDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.FlowData

  @moduletag :db_free

  defmodule RecordingSRQL do
    @moduledoc false

    def query(query, _opts) do
      send(Process.get(:flow_data_test_pid), {:flow_query, query})
      {:ok, %{"results" => [], "pagination" => %{}}}
    end
  end

  test "default device flow inventory is bounded to the last 24 hours" do
    Process.put(:flow_data_test_pid, self())

    assert {[], %{}, nil} = FlowData.load_flows(RecordingSRQL, "sr:router-1", :scope, nil, 50)
    assert_receive {:flow_query, query}
    assert query == ~s|in:flows device_id:"sr:router-1" time:last_24h sort:time:desc|
  end

  test "presence probe is unsorted limit:1 so it cannot walk the 24h time index" do
    Process.put(:flow_data_test_pid, self())

    refute FlowData.has_flows?(RecordingSRQL, "sr:router-1", :scope)
    assert_receive {:flow_query, query}
    assert query == ~s|in:flows device_id:"sr:router-1" time:last_24h limit:1|
    refute query =~ "sort:"
  end
end
