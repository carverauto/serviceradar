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

  defmodule CollectingSRQL do
    @moduledoc false

    def query(query, _opts) do
      send(:flow_data_collector, {:flow_query, query})
      {:ok, %{"results" => [], "pagination" => %{}}}
    end
  end

  defmodule RaisingSRQL do
    @moduledoc false

    def query(_query, _opts) do
      raise DBConnection.ConnectionError, "connection not available"
    end
  end

  defp collect_queries(fun) do
    Process.register(self(), :flow_data_collector)
    fun.()
    queries = drain_queries([])
    Process.unregister(:flow_data_collector)
    queries
  end

  defp drain_queries(acc) do
    receive do
      {:flow_query, q} -> drain_queries([q | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  describe "load_device_flow_stats/3 fan-out" do
    test "summary is a single query carrying all four aggregates" do
      queries =
        collect_queries(fn ->
          FlowData.load_device_flow_stats(CollectingSRQL, "sr:router-1", :scope)
        end)

      summary =
        Enum.filter(queries, fn q -> String.contains?(q, "total_bytes") end)

      assert length(summary) == 1, "expected one summary query, got #{length(summary)}"

      [summary_query] = summary

      for alias_field <- ~w(total_bytes total_packets flow_count unique_talkers) do
        assert String.contains?(summary_query, alias_field),
               "summary query missing #{alias_field}: #{summary_query}"
      end
    end

    test "a raising SRQL module does not kill the caller and yields an empty bundle" do
      # This is the production shape: DBConnection raises out of every query
      # when the pool drops the checkout. Before crash isolation this exit
      # signal propagated through the fan-out and killed the LiveView.
      caller = self()

      {summary, sparkline, proto, _chart_keys, chart_points, talkers, destinations, peers, ports, protocols, facets} =
        FlowData.load_device_flow_stats(RaisingSRQL, "sr:router-1", :scope)

      assert Process.alive?(caller)
      assert summary == %{}
      assert facets == %{protocols: [], directions: [], services: []}

      for json <- [sparkline, proto, chart_points, talkers, destinations, peers, ports, protocols] do
        assert json == "[]"
      end
    end
  end
end
