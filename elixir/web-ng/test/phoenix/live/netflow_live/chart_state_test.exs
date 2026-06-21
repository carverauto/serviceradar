defmodule ServiceRadarWebNGWeb.NetflowLive.ChartStateTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.ChartState

  @moduletag :unit
  @moduletag :db_free

  test "classifies empty chart payloads as no-data with flow settings link" do
    state = ChartState.for_chart_payload("grid", [], [])

    assert state.kind == :no_data
    assert state.title == "No chart data"
    assert state.link_href == "/settings/flows"
  end

  test "classifies empty sankey edges separately from chart buckets" do
    state = ChartState.for_sankey_edges([])

    assert state.kind == :no_data
    assert state.title == "No Sankey data"
    assert state.detail =~ "conversations"
  end

  test "does not emit an empty state when chart data is present" do
    assert is_nil(ChartState.for_chart_payload("lines", ["src"], [%{"t" => "2026-01-01T00:00:00Z", "src" => 1}]))
    assert is_nil(ChartState.for_sankey_edges([%{source: "a", target: "b", bytes: 10}]))
  end

  test "builds distinct query-error and disabled states" do
    query_error = ChartState.query_error("Chart query", {:bad_srql, "unexpected token"})
    disabled = ChartState.disabled_from_srql(%{enabled: false})

    assert query_error.kind == :query_error
    assert query_error.title == "Chart query failed"
    assert query_error.link_href == nil

    assert disabled.kind == :disabled
    assert disabled.title == "Flow charting disabled"
    assert disabled.link_href == "/admin/collectors"
  end
end
