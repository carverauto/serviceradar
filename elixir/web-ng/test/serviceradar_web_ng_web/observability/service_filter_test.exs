defmodule ServiceRadarWebNGWeb.Observability.ServiceFilterTest do
  @moduledoc """
  The service filter is emitted by web-ng and parsed by the Rust SRQL parser,
  so the parser (through the NIF) is the oracle here: a token is only correct
  if SRQL reads back exactly the names that went in, as an exact match.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNGWeb.Observability.ServiceFilter
  alias ServiceRadarWebNGWeb.ObservabilityPaths

  @moduletag :db_free

  # The parsed `service_name` filter of `query`, as SRQL sees it.
  defp srql_service_filters(query) do
    {:ok, json} = Native.parse_ast(query)

    json
    |> Jason.decode!()
    |> Map.fetch!("filters")
    |> Enum.filter(&(&1["field"] == "service_name"))
  end

  defp exact_names(query) do
    case srql_service_filters(query) do
      [%{"op" => "eq", "value" => name}] -> [name]
      [%{"op" => "in", "value" => names}] -> names
      other -> flunk("expected one exact service_name filter, SRQL parsed #{inspect(other)}")
    end
  end

  describe "emitted tokens are exact matches in SRQL" do
    test "names SRQL would otherwise read as a pattern or comparison stay exact" do
      for names <- [
            ["checkout"],
            ["checkout", "billing"],
            ["pay%"],
            ["%"],
            [">svc-0001"],
            ["svc with spaces"],
            [~s(quote"inside)],
            ["back\\slash"],
            ["checkout", "pay%", ~s(a"b\\c)],
            ["checkout", ~s(quote"inside)],
            ["checkout", "back\\slash"],
            [~s(ends")],
            [~s("starts)],
            ["trailing\\"],
            ["checkout", ~s(ends"), ~s("starts), "trailing\\", "a,b", "(p)", "it's"]
          ] do
        query = ServiceFilter.put("in:logs time:last_1h", names)
        assert exact_names(query) == names, "#{inspect(names)} -> #{query}"
      end
    end

    test "a single plain name uses the quoted scalar form" do
      assert ServiceFilter.put("in:logs", ["billing"]) == ~s(in:logs service_name:"billing")
    end
  end

  describe "put/2" do
    test "keeps every other token and adds the selection" do
      query = ServiceFilter.put("in:logs time:last_1h severity_text:error", ["checkout", "billing"])

      assert query == ~s|in:logs time:last_1h severity_text:error service_name:("checkout","billing")|
      assert exact_names(query) == ["checkout", "billing"]
    end

    test "a new selection replaces the previous service filter, and [] clears it" do
      previous = ~s|in:logs service_name:("checkout","billing") time:last_1h sort:timestamp:desc|

      assert ServiceFilter.put(previous, ["billing"]) ==
               ~s(in:logs time:last_1h sort:timestamp:desc service_name:"billing")

      assert ServiceFilter.put(previous, []) == "in:logs time:last_1h sort:timestamp:desc"
    end

    test "quoted values of other tokens survive untouched" do
      query = ~s|in:logs message:"a \\"quoted\\" (b)" service_name:x|

      assert ServiceFilter.put(query, ["billing"]) ==
               ~s|in:logs message:"a \\"quoted\\" (b)" service_name:"billing"|
    end

    test "a negated service filter is a different filter and is kept" do
      assert ServiceFilter.put("in:logs !service_name:noisy", ["checkout"]) ==
               ~s(in:logs !service_name:noisy service_name:"checkout")
    end
  end

  describe "parse/1 reads back what SRQL reads" do
    test "exact, list, wildcard and unsupported forms" do
      assert ServiceFilter.parse("in:logs") == :none
      assert ServiceFilter.parse(~s(in:logs service_name:"checkout")) == {:exact, ["checkout"]}
      assert ServiceFilter.parse(~s|in:logs SERVICE_NAME:(checkout,"bil ling")|) == {:exact, ["checkout", "bil ling"]}
      assert ServiceFilter.parse("in:logs service_name:%pay%") == {:wildcard, "%pay%"}
      assert ServiceFilter.parse("in:logs service_name:>a") == :unsupported
      assert ServiceFilter.parse("in:logs service_name:a service_name:b") == :unsupported
    end

    test "round-trips every emitted token" do
      for names <- [
            ["checkout", "pay%", ~s(a"b\\c)],
            [~s(ends")],
            ["checkout", ~s(ends"), ~s("starts), "trailing\\", "a,b", "(p)", "it's"]
          ] do
        assert ServiceFilter.parse(ServiceFilter.put("in:logs", names)) == {:exact, names}
      end
    end
  end

  describe "stats_scope/1" do
    test "no filter, exact, and wildcard filters are expressible" do
      assert ServiceFilter.stats_scope("in:logs") == nil
      assert ServiceFilter.stats_scope(~s(in:logs service_name:"checkout")) == ["checkout"]
      assert ServiceFilter.stats_scope("in:logs service_name:%pay%") == "%pay%"
    end

    test "a filter the cards cannot express reads as all services" do
      assert ServiceFilter.stats_scope("in:logs service_name:>a") == :all_services
      assert ServiceFilter.stats_scope("in:logs !service_name:noisy") == :all_services
      assert ServiceFilter.stats_scope("in:logs !SERVICE_NAME:(a,b)") == :all_services
      assert ServiceFilter.stats_scope("in:logs service_name:checkout !service_name:noisy") == :all_services
    end
  end

  describe "tab links carry the service filter" do
    defp decoded_q(path) do
      path |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("q")
    end

    test "an exact selection is carried into the other signal panes' default queries" do
      paths =
        ObservabilityPaths.service_carry_paths(
          "logs",
          ~s|in:logs severity_text:error service_name:("checkout","billing")|
        )

      assert paths |> Map.keys() |> Enum.sort() == ["metrics", "traces"]

      traces_q = decoded_q(paths["traces"])
      assert traces_q =~ "in:otel_trace_summaries"
      refute traces_q =~ "severity_text"
      assert exact_names(traces_q) == ["checkout", "billing"]
      assert exact_names(decoded_q(paths["metrics"])) == ["checkout", "billing"]
    end

    test "a wildcard is dropped for trace summaries, with a notice, and kept for metrics" do
      paths = ObservabilityPaths.service_carry_paths("logs", "in:logs service_name:%pay%")

      traces = URI.parse(paths["traces"])
      assert traces.path == "/observability/traces"
      assert ObservabilityPaths.service_filter_not_carried?(URI.decode_query(traces.query))

      assert [%{"op" => "like", "value" => "%pay%"}] = srql_service_filters(decoded_q(paths["metrics"]))
    end

    test "no filter leaves the plain tab links, and non-signal panes carry nothing" do
      assert ObservabilityPaths.service_carry_paths("traces", "in:otel_trace_summaries") == %{
               "logs" => "/observability/logs",
               "metrics" => "/observability/metrics"
             }

      assert ObservabilityPaths.service_carry_paths("events", ~s(in:logs service_name:"checkout")) == %{}
    end
  end
end
