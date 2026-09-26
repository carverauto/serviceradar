defmodule ServiceRadarWebNGWeb.StatsServiceFilterTest do
  @moduledoc """
  Stat-card rollups take the pane's service selection as a list and hand it to
  SRQL as a list filter: every name, exact, never truncated. The SRQL parser
  (through the NIF) is the oracle for what the rollup will filter on.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Query

  @moduletag :db_free

  defp service_filter(query) do
    {:ok, json} = Native.parse_ast(query)

    json
    |> Jason.decode!()
    |> Map.fetch!("filters")
    |> Enum.filter(&(&1["field"] == "service_name"))
  end

  # More than one name, one that SRQL would read as a pattern if it were a
  # scalar, and a full 20-name selection.
  @selection ["checkout", "pay%"] ++ Enum.map(3..20, &"svc-#{String.pad_leading("#{&1}", 4, "0")}")

  test "every OTel card rollup applies the whole selection as an exact list filter" do
    queries = [
      Query.logs_severity(service_name: @selection),
      Query.traces_summary(service_name: @selection),
      Query.metrics_red(service_name: @selection),
      Query.logs_severity_data_query(:error, service_name: @selection),
      Query.otel_service_count("traces", service_name: @selection)
    ]

    for query <- queries do
      assert [%{"op" => "in", "value" => @selection}] = service_filter(query), query
    end
  end

  test "a single pattern string is kept as the pane's wildcard" do
    assert [%{"op" => "like", "value" => "%pay%"}] =
             service_filter(Query.logs_severity(service_name: "%pay%"))
  end

  test "no selection leaves the rollup unfiltered" do
    unfiltered = [
      Query.logs_severity(service_name: []),
      Query.traces_summary(),
      Query.metrics_red(service_name: nil)
    ]

    for query <- unfiltered do
      assert service_filter(query) == [], query
    end
  end

  describe "trace_summary_counts/2" do
    # The traces pane's service filter matches any participating span, so its
    # counts must come from `in:otel_trace_summaries`, not the root-grouped
    # `rollup_stats:summary`, with the list's own filter and window.
    test "counts from trace summaries with the list's filter and window, and errors separately" do
      {total_query, errors_query} = Query.trace_summary_counts(@selection, time: "last_6h")

      for query <- [total_query, errors_query] do
        assert %{"entity" => "trace_summaries", "stats" => %{"raw" => "count() as total"}} = ast(query)
        assert [%{"op" => "in", "value" => @selection}] = service_filter(query)
        refute query =~ "rollup_stats"
        assert query =~ "time:last_6h"
      end

      assert [%{"op" => "gt", "value" => "0"}] = ast_filters(errors_query, "error_count")
      assert ast_filters(total_query, "error_count") == []
    end

    defmodule SummaryCountStub do
      @moduledoc false
      def query(query, %{scope: :scope}) do
        total = if query =~ "error_count", do: 1, else: 3
        {:ok, %{"results" => [%{"total" => total}]}}
      end
    end

    test "returns both counts" do
      assert {:ok, %{total: 3, errors: 1}} =
               Stats.trace_summary_counts(["billing"], srql_module: SummaryCountStub, scope: :scope)
    end
  end

  defp ast(query) do
    {:ok, json} = Native.parse_ast(query)
    Jason.decode!(json)
  end

  defp ast_filters(query, field), do: query |> ast() |> Map.fetch!("filters") |> Enum.filter(&(&1["field"] == field))

  describe "otel_service_count/2" do
    defmodule CountStub do
      @moduledoc false
      def query(query, %{scope: :scope}) do
        send(self(), {:count_query, query})
        Process.get(:count_response)
      end
    end

    test "returns the catalog count, and a failure as an error rather than zero" do
      Process.put(:count_response, {:ok, %{"results" => [%{"total" => 42}]}})

      assert {:ok, 42} = Stats.otel_service_count("traces", srql_module: CountStub, scope: :scope)
      assert_received {:count_query, ~s|in:otel_services signal:traces time:last_24h stats:"count() as total"|}

      Process.put(:count_response, {:error, :timeout})
      assert {:error, :timeout} = Stats.otel_service_count("traces", srql_module: CountStub, scope: :scope)
    end
  end
end
