defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowListTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowList

  @moduletag :db_free

  test "load_srql_assigns preserves a mode-invalid query on the desynchronized freeform path" do
    query =
      "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total series:app " <>
        "tag:edge limit:100"

    socket =
      %Socket{}
      |> Phoenix.Component.assign(:srql, %{builder_mode_notice: "stale notice"})
      |> FlowList.load_srql_assigns(query, "/observability/flows", 100)

    assert socket.assigns.srql.query == query
    assert socket.assigns.srql.draft == query
    refute socket.assigns.srql.builder_supported
    refute socket.assigns.srql.builder_sync
    assert socket.assigns.srql.builder_mode_notice == nil
  end
end
