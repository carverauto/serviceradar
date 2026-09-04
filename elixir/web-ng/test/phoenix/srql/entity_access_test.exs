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

  # The parser accepting `in:merge_audit` is not the same thing as the gate
  # knowing about it. `permission_for_query/1` returns `:passthrough` for
  # unknown entities so the SRQL compiler stays the source of that error -- which
  # means an alias the Rust parser accepts but this map omits is an UNGATED
  # entity on the HTTP and MCP paths, and it fails open silently. Enumerate every
  # alias rather than spot-checking one per entity.
  @identity_diagnostic_aliases [
    {"merge_audit", ~w(merge_audit device_merges merges)},
    {"device_revival_audit", ~w(device_revival_audit device_revivals revivals)},
    {"device_identifiers", ~w(device_identifiers identifiers device_identity)},
    {"identity_reconciliation_runs", ~w(identity_reconciliation_runs reconciliation_runs dire_runs)},
    {"identity_evidence_edges", ~w(identity_evidence_edges identity_evidence evidence_edges)}
  ]

  test "every identity diagnostic alias is gated by devices.view, never passthrough" do
    unmapped =
      for {_canonical, aliases} <- @identity_diagnostic_aliases,
          entity <- aliases,
          EntityAccess.permission_for_entity(entity) != {:ok, "devices.view"} do
        {entity, EntityAccess.permission_for_entity(entity)}
      end

    assert unmapped == [],
           "identity diagnostic aliases missing from the RBAC map: #{inspect(unmapped)}"
  end

  test "every identity diagnostic alias the RBAC map claims is accepted by the parser" do
    # The inverse direction: a map entry for an alias the parser rejects is dead
    # weight that hides a typo.
    unsupported =
      for {_canonical, aliases} <- @identity_diagnostic_aliases,
          entity <- aliases,
          not match?({:ok, _}, Native.parse_ast("in:#{entity} limit:1")) do
        entity
      end

    assert unsupported == []
  end

  test "a query naming an identity diagnostic entity resolves through permission_for_query" do
    assert {:ok, "devices.view"} =
             EntityAccess.permission_for_query("in:merge_audit chain:sr:aaa")

    assert {:ok, "devices.view"} =
             EntityAccess.permission_for_query("in:evidence_edges device:sr:aaa limit:10")
  end

  test "a caller without devices.view is refused an identity diagnostic query" do
    scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

    assert {:error, :forbidden} =
             EntityAccess.authorize("in:merge_audit limit:10", scope)

    assert {:error, :forbidden} =
             EntityAccess.authorize("in:identity_reconciliation_runs limit:10", scope)
  end

  test "parser aliases resolve to the same catalog key as the canonical entity" do
    assert EntityAccess.permission_for_entity("device") ==
             EntityAccess.permission_for_entity("devices")

    assert EntityAccess.permission_for_entity("flow") ==
             EntityAccess.permission_for_entity("flows")

    assert EntityAccess.permission_for_entity("cves") ==
             EntityAccess.permission_for_entity("vulnerability_advisories")

    assert EntityAccess.permission_for_entity("advisories") ==
             EntityAccess.permission_for_entity("vulnerability_advisories")

    assert EntityAccess.permission_for_entity("advisory_cpes") ==
             EntityAccess.permission_for_entity("advisory_coordinates")

    assert EntityAccess.permission_for_entity("cve_matches") ==
             EntityAccess.permission_for_entity("endpoint_vulnerability_matches")

    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("cves")
    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("advisory_cpes")
    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("cve_matches")

    assert EntityAccess.permission_for_entity("ioc_matches") ==
             EntityAccess.permission_for_entity("threat_intel_matches")

    assert {:ok, "observability.netflow.view"} =
             EntityAccess.permission_for_entity("threat_intel_matches")

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

  describe "extract_entity/1 token position" do
    test "resolves the entity when in: is not the first token" do
      assert EntityAccess.extract_entity("limit:1 in:devices") == "devices"
      assert EntityAccess.extract_entity("time:last_24h in:devices limit:5") == "devices"
      assert EntityAccess.extract_entity("sort:name:asc in:devices") == "devices"
    end

    test "gates a non-leading entity token the same as a leading one" do
      scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

      assert {:error, :forbidden} = EntityAccess.authorize("in:devices limit:1", scope)
      assert {:error, :forbidden} = EntityAccess.authorize("limit:1 in:devices", scope)
    end
  end
end
