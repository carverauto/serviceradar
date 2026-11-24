defmodule ServiceRadarWebNG.SRQL.HorizonIspAccountabilityAccessTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL.EntityAccess

  @moduletag :db_free

  test "horizon_isp_accountability requires observability.events.view" do
    events_scope = %Scope{user: nil, permissions: MapSet.new(["observability.events.view"])}
    traces_scope = %Scope{user: nil, permissions: MapSet.new(["observability.traces.view"])}

    assert {:ok, "observability.events.view"} =
             EntityAccess.permission_for_entity("horizon_isp_accountability")

    assert {:ok, _ast} = Native.parse_ast("in:horizon_isp_accountability limit:1")
    assert :ok = EntityAccess.authorize("in:horizon_isp_accountability limit:1", events_scope)

    assert {:error, :forbidden} =
             EntityAccess.authorize("in:horizon_isp_accountability limit:1", traces_scope)

    assert {:error, :forbidden} =
             EntityAccess.authorize("in:horizon_isp_accountability limit:1", nil)
  end

  test "horizon_isp_accountability_mv alias is forbidden by RBAC and rejected by parser" do
    admin_like = %Scope{
      user: nil,
      permissions: MapSet.new(["observability.events.view", "observability.traces.view"])
    }

    assert :unknown = EntityAccess.permission_for_entity("horizon_isp_accountability_mv")

    assert {:error, :forbidden} =
             EntityAccess.authorize("in:horizon_isp_accountability_mv limit:1", admin_like)

    assert {:error, _reason} = Native.parse_ast("in:horizon_isp_accountability_mv limit:1")
  end

  test "case-insensitive and trailing horizon_isp_accountability tokens cannot bypass RBAC" do
    traces_only = %Scope{user: nil, permissions: MapSet.new(["observability.traces.view"])}
    events_only = %Scope{user: nil, permissions: MapSet.new(["observability.events.view"])}

    assert {:error, :forbidden} =
             EntityAccess.authorize("IN:horizon_isp_accountability limit:1", traces_only)

    assert {:error, :forbidden} =
             EntityAccess.authorize(
               "in:horizon_paths limit:1 IN:horizon_isp_accountability",
               traces_only
             )

    assert :ok =
             EntityAccess.authorize(
               "in:horizon_paths limit:1 in:horizon_isp_accountability",
               events_only
             )
  end
end
