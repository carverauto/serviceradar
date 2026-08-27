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

  describe "device_scope_token/1" do
    test "falls back to device_id: when the endpoints cannot be resolved" do
      # No Repo in db_free tests, which is the same shape as a pool failure.
      # The fallback matters: an unresolvable device must still produce a
      # correctly-scoped query, never an empty `ip:[]` that SRQL would drop
      # (widening the query to every flow in the window).
      token = FlowData.device_scope_token("sr:router-1")

      assert token == ~s|device_id:"sr:router-1"|
      refute token =~ "ip:[]"
    end

    test "never emits an empty list filter for a blank device uid" do
      # An empty list would be worse than the slow query: device_addr:[] matches
      # nothing, and dropping the scope entirely would widen to every flow.
      assert FlowData.device_scope_token("") =~ "device_id:"
      refute FlowData.device_scope_token("") =~ "device_addr:["
    end
  end

  describe "load_device_flow_stats/3 fan-out" do
    test "count_distinct is kept out of the SUM/COUNT summary query" do
      # Not a style preference. COUNT(DISTINCT ...) has no partial-aggregate
      # form, so folding it in with the SUMs costs the whole statement its
      # parallel plan (measured on demo: Finalize Aggregate cost 89_314 ->
      # single-threaded Aggregate cost 153_077). The combined statement never
      # finished inside the batch budget, so every stat card rendered 0.
      queries =
        collect_queries(fn ->
          FlowData.load_device_flow_stats(CollectingSRQL, "sr:router-1", :scope)
        end)

      sums = Enum.filter(queries, &String.contains?(&1, "total_bytes"))
      distinct = Enum.filter(queries, &String.contains?(&1, "unique_talkers"))

      assert length(sums) == 1, "expected one SUM/COUNT summary query, got #{length(sums)}"
      assert length(distinct) == 1, "expected one distinct query, got #{length(distinct)}"

      [sum_query] = sums
      [distinct_query] = distinct

      refute sum_query == distinct_query,
             "the distinct aggregate must not share a statement with the SUMs"

      refute String.contains?(sum_query, "count_distinct"),
             "SUM/COUNT query must stay parallel-safe: #{sum_query}"

      for alias_field <- ~w(total_bytes total_packets flow_count) do
        assert String.contains?(sum_query, alias_field),
               "SUM/COUNT query missing #{alias_field}: #{sum_query}"
      end
    end

    test "a failing distinct query does not blank the other three stat cards" do
      # The groups are queried separately so they fail independently.
      defmodule PartialSRQL do
        @moduledoc false
        def query(query, _opts) do
          if String.contains?(query, "unique_talkers") do
            {:error, :timeout}
          else
            {:ok,
             %{
               "results" => [
                 %{"total_bytes" => 4200.0, "total_packets" => 7.0, "flow_count" => 3.0}
               ]
             }}
          end
        end
      end

      {summary, _, _, _, _, _, _, _, _, _, _} =
        FlowData.load_device_flow_stats(PartialSRQL, "sr:router-1", :scope)

      assert summary[:total_bytes] == 4200.0
      assert summary[:total_packets] == 7.0
      assert summary[:flow_count] == 3.0
      refute Map.has_key?(summary, :unique_talkers)
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
