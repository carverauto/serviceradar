defmodule ServiceRadarWebNGWeb.LogLive.NetflowDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.Index

  @moduletag :db_free

  def query(query, %{scope: nil}) do
    send(self(), {:query, query})

    rows =
      cond do
        String.contains?(query, "bucket:") ->
          [%{"timestamp" => "2000-01-01T00:00:00Z", "value" => 100, "series" => "tcp"}]

        String.contains?(query, ~s|stats:"count(*) as total by protocol_num"|) ->
          [%{"protocol_num" => 6, "total" => 240}]

        String.contains?(query, ~s|stats:"count(*) as total"|) ->
          [%{"total" => 240}]

        String.contains?(query, ~s|stats:"sum(bytes_total) as total_bytes"|) ->
          [%{"total_bytes" => 24_000}]

        String.contains?(query, ~s|stats:"sum(packets_total) as total_packets"|) ->
          [%{"total_packets" => 480}]

        String.contains?(query, "by dst_endpoint_port") ->
          [%{"dst_endpoint_port" => 443, "total_bytes" => 24_000}]

        String.contains?(query, "by app") ->
          [%{"app" => "synthetic-app", "total_bytes" => 24_000}]

        true ->
          []
      end

    {:ok, %{"results" => rows}}
  end

  test "overview lines use only four full-window totals and the visible total chart" do
    for range <- ["last_7d", "last_30d"] do
      data = Index.load_netflow_assigns(context("overview", "lines", range), __MODULE__)
      queries = queries()
      assert length(queries) == 5
      assert Enum.all?(queries, &String.contains?(&1, "time:#{range}"))
      assert Enum.count(queries, &String.contains?(&1, "bucket:")) == 1
      assert data.netflow_summary.total == 240
      assert data.netflow_sankey.edges == []
      assert data.netflow_geo_heatmap == []
      assert data.netflow_protocol_activity.points == []
      assert data.netflow_app_activity.points == []
      assert data.netflow_timeseries_stacked.points == []
    end
  end

  test "overview stacked loads its selected series without hidden activity or topology scans" do
    data = Index.load_netflow_assigns(context("overview", "stacked"), __MODULE__)
    queries = queries()
    assert length(queries) == 7
    assert Enum.count(queries, &String.contains?(&1, "dst_port:443")) == 1
    assert data.netflow_timeseries_stacked.keys != []
    refute Enum.any?(queries, &String.contains?(&1, "series:protocol_group"))
    refute Enum.any?(queries, &String.contains?(&1, "by app"))
    refute Enum.any?(queries, &String.contains?(&1, "country_iso2"))
    refute Enum.any?(queries, &String.contains?(&1, "src_endpoint_ip, dst_endpoint_port"))
  end

  test "traffic loads activity charts without overview totals, talkers, or topology" do
    for {graph, expected_count} <- [{"lines", 4}, {"stacked", 6}] do
      data = Index.load_netflow_assigns(context("traffic", graph), __MODULE__)
      queries = queries()
      assert length(queries) == expected_count
      assert Enum.any?(queries, &String.contains?(&1, "series:protocol_group"))
      assert Enum.any?(queries, &String.contains?(&1, "series:app"))
      refute Enum.any?(queries, &String.contains?(&1, "count(*) as total"))
      assert data.netflow_summary.total == 0
      assert data.netflow_top_talkers == []
      assert data.netflow_sankey.edges == []
    end
  end

  test "topology loads only geo and Sankey" do
    Index.load_netflow_assigns(context("topology", "sankey"), __MODULE__)
    queries = queries()
    assert length(queries) == 2
    assert Enum.any?(queries, &String.contains?(&1, "country_iso2"))
    assert Enum.any?(queries, &String.contains?(&1, "src_endpoint_ip, dst_endpoint_port, dst_endpoint_ip"))
  end

  test "talkers loads its two rankings and the Sankey-backed icicle" do
    Index.load_netflow_assigns(context("talkers", "stacked"), __MODULE__)
    queries = queries()
    assert length(queries) == 3
    assert Enum.any?(queries, &String.contains?(&1, "by src_endpoint_ip\""))
    assert Enum.any?(queries, &String.contains?(&1, "by dst_endpoint_port\""))
    assert Enum.any?(queries, &String.contains?(&1, "src_endpoint_ip, dst_endpoint_port, dst_endpoint_ip"))
  end

  test "raw explorer views issue no unused aggregate queries" do
    for view <- ["explorer", "all"] do
      data = Index.load_netflow_assigns(context(view, "stacked"), __MODULE__)
      assert queries() == []
      assert data.netflow_timeseries.points == []
      assert data.netflow_sankey.edges == []
    end
  end

  test "comparison is queried only when a line or grid chart renders it" do
    context = Map.put(context("overview", "lines"), :netflow_compare_mode, "previous")
    Index.load_netflow_assigns(context, __MODULE__)
    assert length(queries()) == 6

    Index.load_netflow_assigns(%{context | netflow_graph_mode: "stacked"}, __MODULE__)
    queries = queries()
    assert length(queries) == 7
    refute Enum.any?(queries, &String.contains?(&1, "time:["))
  end

  defp context(view, graph, range \\ "last_7d") do
    %{
      current_scope: nil,
      srql: %{query: "in:flows time:#{range}"},
      netflows: [],
      netflow_view: view,
      netflow_graph_mode: graph
    }
  end

  defp queries(acc \\ []) do
    receive do
      {:query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
