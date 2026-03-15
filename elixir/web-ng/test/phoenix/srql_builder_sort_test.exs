defmodule ServiceRadarWebNGWeb.SRQLBuilderSortTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder

  test "builds default devices query with sort and limit" do
    state = Builder.default_state("devices", 100)
    query = Builder.build(state)

    assert query =~ "in:devices"
    assert query =~ "sort:last_seen:desc"
    assert query =~ "limit:100"
  end

  test "builds default logs query with sort and limit" do
    state = Builder.default_state("logs", 50)
    query = Builder.build(state)

    assert query =~ "in:logs"
    assert query =~ "sort:timestamp:desc"
    assert query =~ "limit:50"
  end

  test "filters do not break sort and limit assembly" do
    state =
      "devices"
      |> Builder.default_state(25)
      |> Map.put("filters", [
        %{"field" => "hostname", "op" => "contains", "value" => "srv"}
      ])

    query = Builder.build(state)

    assert query =~ "hostname:%srv%"
    assert query =~ "sort:last_seen:desc"
    assert query =~ "limit:25"
  end
end
