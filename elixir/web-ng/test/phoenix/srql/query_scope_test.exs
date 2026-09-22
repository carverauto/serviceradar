defmodule ServiceRadarWebNG.SRQL.QueryScopeTest do
  @moduledoc """
  Gate regression for the LiveView detail-loader authz hole.

  Detail loaders used to call `SRQL.query/1` without a principal, and the
  catalog gate treated a missing scope as optional. Now every entry path
  denies a mapped entity when the scope is missing or lacks the catalog
  permission, so a custom role without e.g. `observability.logs.view`
  gets an error on `/logs/:id`, not the row.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL
  alias ServiceRadarWebNGWeb.GatewayLive.Show, as: GatewayShow

  @moduletag :db_free

  @logs_query ~s(in:logs id:"550e8400-e29b-41d4-a716-446655440000" time:last_24h limit:1)

  test "query/2 without scope is forbidden for a mapped entity" do
    assert {:error, :forbidden} = SRQL.query(@logs_query, %{})
  end

  test "query_request/1 without scope is forbidden for a mapped entity" do
    assert {:error, :forbidden} = SRQL.query_request(%{"query" => @logs_query})
  end

  test "query_arrow/2 without scope is forbidden for a mapped entity" do
    assert {:error, :forbidden} = SRQL.query_arrow(@logs_query, %{})
  end

  test "query/2 with a scope lacking the catalog permission is forbidden" do
    scope = %Scope{user: nil, permissions: MapSet.new(["devices.view"])}

    assert {:error, :forbidden} = SRQL.query(@logs_query, %{scope: scope})
  end

  test "gateway details deny access before loading live or database data" do
    for scope <- [nil, %Scope{user: %{id: "synthetic-user"}, permissions: MapSet.new(["services.view"])}] do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_scope: scope, flash: %{}}
      }

      {:ok, socket} = GatewayShow.mount(%{}, %{}, socket)

      assert {:noreply, denied} =
               GatewayShow.handle_params(%{"gateway_id" => "gateway01"}, "/gateways/gateway01", socket)

      assert {:live, :redirect, %{to: "/dashboard"}} = denied.redirected
      assert denied.assigns.flash["error"] == "You do not have permission to view gateways."
      assert is_nil(denied.assigns.gateway)
      assert is_nil(denied.assigns.live_gateway)
      assert is_nil(denied.assigns.node_info)
      assert is_nil(denied.assigns.gateway_id)
    end
  end
end
