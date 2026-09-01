defmodule ServiceRadarWebNG.SRQL.EntityAccessTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL.EntityAccess
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  # Interface settings are managed through the Ash-backed
  # ServiceRadar.Inventory.InterfaceSettings context, not the Rust SRQL engine.
  @non_rust_srql_entities MapSet.new(["interface_settings"])

  test "every catalog entity other than dashboards has a permission mapping" do
    unmapped =
      Catalog.entities()
      |> Enum.map(& &1.id)
      |> Enum.reject(fn id ->
        id == "dashboards" or match?({:ok, _}, EntityAccess.permission_for_entity(id))
      end)

    assert unmapped == []
  end

  test "every Rust-backed catalog entity is accepted by the shared Rust parser" do
    unsupported =
      Catalog.entities()
      |> Enum.map(& &1.id)
      |> Enum.reject(fn entity ->
        MapSet.member?(@non_rust_srql_entities, entity) or
          match?({:ok, _ast_json}, Native.parse_ast("in:#{entity} limit:1"))
      end)

    assert unsupported == []
  end

  test "parser aliases resolve to the same catalog key as the canonical entity" do
    assert EntityAccess.permission_for_entity("device") ==
             EntityAccess.permission_for_entity("devices")

    assert EntityAccess.permission_for_entity("flow") ==
             EntityAccess.permission_for_entity("flows")

    assert {:ok, "observability.logs.view"} = EntityAccess.permission_for_entity("logs")
    assert {:ok, "services.view"} = EntityAccess.permission_for_entity("services")
    assert :passthrough = EntityAccess.permission_for_entity("dashboards")
    assert :passthrough = EntityAccess.permission_for_entity("not_a_real_entity_zzz")
  end

  test "extract_entity reads in: tokens and quoted aliases" do
    assert EntityAccess.extract_entity("in:devices limit:10") == "devices"
    assert EntityAccess.extract_entity(~s(in:"Devices" hostname:x)) == "devices"
  end

  test "authorize denies devices.view and allows logs.view for a custom permission set" do
    scope =
      %Scope{
        user: %{id: "user-1", email: "custom@localhost"},
        permissions: MapSet.new(["observability.logs.view"])
      }

    assert {:error, :forbidden} = EntityAccess.authorize("in:devices", scope)
    assert :ok = EntityAccess.authorize("in:logs", scope)
    assert :ok = EntityAccess.authorize("in:dashboards", scope)
    assert :ok = EntityAccess.authorize("in:not_a_real_entity_zzz", scope)
  end

  test "authorize without optional_scope forbids a missing scope" do
    assert {:error, :forbidden} = EntityAccess.authorize("in:devices", nil)
    assert :ok = EntityAccess.authorize("in:devices", nil, optional_scope: true)
  end
end
