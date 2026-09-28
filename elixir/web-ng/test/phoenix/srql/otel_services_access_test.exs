defmodule ServiceRadarWebNG.SRQL.OtelServicesAccessTest do
  @moduledoc """
  `in:otel_services` through the real web-ng query paths and the real SRQL NIF.

  Every case here is refused before a database is touched: by the web-ng gate
  (no observability view at all), by the SRQL planner (a `signal:` outside the
  permitted set, surfaced as `{:error, :forbidden}`), or as a malformed request
  (surfaced as SRQL's own error). The narrowing of an admitted query is proven
  against a database in `otel_services_access_db_test.exs`.
  """
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.SRQL

  @moduletag :db_free

  setup do
    # Access routes through the configured SRQL module; exercise the real one.
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.delete_env(:serviceradar_web_ng, :srql_module)

    on_exit(fn ->
      if previous, do: Application.put_env(:serviceradar_web_ng, :srql_module, previous)
    end)

    :ok
  end

  defp logs_only, do: %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

  @other_signal_queries [
    "in:otel_services signal:traces",
    "in:otel_services SIGNAL:traces",
    "in:otel_services signal:(logs,traces)",
    "in:otel_services signal:metrics service_name:%pay%"
  ]

  test "a logs-only caller asking for another signal is forbidden on every query path" do
    for query <- @other_signal_queries do
      assert {:error, :forbidden} = SRQL.query(query, %{scope: logs_only()}), "LiveView: #{query}"

      assert {:error, :forbidden} = Access.execute_query(logs_only(), %{"query" => query}),
             "HTTP/MCP: #{query}"

      assert {:error, :forbidden} = SRQL.query_arrow(query, %{scope: logs_only()}), "Arrow: #{query}"
    end
  end

  test "a caller with no observability view is refused by the gate" do
    scope = %Scope{user: nil, permissions: MapSet.new(["devices.view"])}

    assert {:error, :forbidden} = SRQL.query("in:otel_services", %{scope: scope})
    assert {:error, :forbidden} = Access.execute_query(scope, %{"query" => "in:otel_services"})
  end

  test "a missing scope is forbidden" do
    assert {:error, :forbidden} = SRQL.query("in:otel_services signal:logs", %{scope: nil})
  end

  test "a repeated or negated signal token is an invalid request, not a permission failure" do
    for query <- ["in:otel_services signal:logs signal:traces", "in:otel_services !signal:logs"] do
      assert {:error, reason} = SRQL.query(query, %{scope: logs_only()})
      assert is_binary(reason) and reason =~ "invalid request", "#{query} -> #{inspect(reason)}"
    end
  end
end
