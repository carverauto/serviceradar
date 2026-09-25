defmodule ServiceRadarWebNGWeb.DashboardLive.QueryResultsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DashboardLive.Index
  alias ServiceRadarWebNGWeb.DashboardLive.Index.QueryResults
  alias ServiceRadarWebNGWeb.SRQL.Page

  @moduletag :db_free
  @query ~s(in:timeseries_metrics uid:"sr:host-alpha" metric_type:icmp time:last_1h bucket:5m agg:avg series:metric_name limit:1000)

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    :ok
  end

  test "a metric query routed to the dashboard executes with scope and displays its timestamp, series and value" do
    row = %{"timestamp" => "1999-06-15T00:00:00Z", "series" => "icmp_response_time_ns", "value" => 250_000}
    Process.put(:dashboard_query_response, {:ok, %{"results" => [row]}})

    assert Page.route_target_for_query(@query, "/devices") == {"/dashboard", %{}}
    socket = load_query()
    assert_receive {:dashboard_query, @query, %{limit: 1000, scope: %{test_pid: owner}}}
    assert owner == self()
    assert socket.assigns.query_results == [row]

    document = render_results(socket)
    assert LazyHTML.text(LazyHTML.query(document, "#dashboard-query-table")) =~ "icmp_response_time_ns"
    assert LazyHTML.text(document) =~ "250,000"
    assert LazyHTML.attribute(LazyHTML.query(document, "time"), "datetime") == ["1999-06-15T00:00:00Z"]
  end

  test "empty results and query failures are displayed explicitly" do
    Process.put(:dashboard_query_response, {:ok, %{"results" => []}})
    assert load_query() |> render_results() |> LazyHTML.text() =~ "No results for this query and time window."

    Process.put(:dashboard_query_response, {:error, "invented query failure"})
    document = load_query() |> render_results()
    assert LazyHTML.text(LazyHTML.query(document, "#dashboard-query-error")) =~ "invented query failure"
  end

  test "pagination executes the next cursor while preserving query and scope" do
    Process.put(:dashboard_query_response, {:ok, %{"results" => [], "pagination" => %{"next_cursor" => "next-page"}}})
    socket = load_query()
    assert_receive {:dashboard_query, @query, _}

    assert {:noreply, socket} = Index.handle_event("srql_paginate", %{"cursor" => "next-page", "page" => "2"}, socket)
    assert_receive {:dashboard_query, @query, %{cursor: "next-page", scope: %{test_pid: owner}}}
    assert owner == self()
    assert socket.assigns.pagination_page == 2
  end

  def query(query, opts) do
    send(opts.scope.test_pid, {:dashboard_query, query, opts})
    Process.get(:dashboard_query_response)
  end

  defp load_query do
    socket = %Socket{assigns: %{__changed__: %{}, current_scope: %{test_pid: self()}}}
    {:noreply, socket} = Index.handle_params(%{"q" => @query}, "/dashboard?#{URI.encode_query(%{"q" => @query})}", socket)
    socket
  end

  defp render_results(socket) do
    render_component(&QueryResults.render/1,
      rows: socket.assigns.query_results,
      srql: socket.assigns.srql,
      limit: socket.assigns.limit,
      current_page: socket.assigns.pagination_page,
      timezone: "Etc/UTC"
    )
    |> LazyHTML.from_fragment()
  end
end
