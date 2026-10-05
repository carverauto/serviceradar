defmodule ServiceRadarWebNG.SRQL.EntityAccessTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL.EntityAccess
  alias ServiceRadarWebNG.SRQL.FleetQuery
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog
  alias ServiceRadarWebNGWeb.SRQL.Page

  @moduletag :db_free

  # Interface settings are managed through the Ash-backed
  # ServiceRadar.Inventory.InterfaceSettings context, not the Rust SRQL engine.
  @non_rust_srql_entities MapSet.new(["interface_settings"])

  test "fleet aliases require their own permissions and use the canonical builder catalog" do
    devices = %Scope{permissions: MapSet.new(["devices.view"])}
    plugins = %Scope{permissions: MapSet.new(["plugins.view"])}

    for entity <- ~w(plugin_fleet plugin_fleets) do
      assert :ok = EntityAccess.authorize("in:#{entity}", plugins)
      assert {:error, :forbidden} = EntityAccess.authorize("in:#{entity}", devices)
      assert {:error, :forbidden} = EntityAccess.authorize("in:#{entity}", nil)
      assert Catalog.entity(entity).id == "plugin_fleet"
      assert {:ok, _ast} = Native.parse_ast("in:#{entity} sort:category:asc")
    end

    for {entity, canonical} <- [{"addon_fleets", "addon_fleet"}, {"addon_status", "addon_statuses"}] do
      assert :ok = EntityAccess.authorize("in:#{entity}", devices)
      assert {:error, :forbidden} = EntityAccess.authorize("in:#{entity}", plugins)
      assert Catalog.entity(entity).id == canonical
    end
  end

  test "security events require the audit permission even for an events reader" do
    events_reader = %Scope{user: nil, permissions: MapSet.new(["observability.events.view"])}
    auditor = %Scope{user: nil, permissions: MapSet.new(["settings.audit.view"])}

    assert {:ok, _} = Native.parse_ast("in:security_events limit:1")
    assert {:error, :forbidden} = EntityAccess.authorize("in:security_events", events_reader)
    assert {:error, :forbidden} = EntityAccess.authorize("in:security_events", nil)
    assert :ok = EntityAccess.authorize("in:security_events", auditor)
  end

  test "fleet builder timestamp filters compile and match observation timestamps" do
    timestamp = ~U[2026-01-15 12:00:00Z]

    for {entities, fields} <- [
          {~w(addon_fleet addon_fleets), ~w(reported_at last_health_at last_scan_at)},
          {~w(plugin_fleet plugin_fleets), ~w(reported_at last_success_at last_failure_at)}
        ],
        entity <- entities,
        field <- fields do
      query =
        entity
        |> Builder.default_state()
        |> Map.put("filters", [
          %{
            "field" => field,
            "op" => Catalog.default_filter_op(entity, field),
            "value" => DateTime.to_iso8601(timestamp)
          }
        ])
        |> Builder.build()

      assert {:ok, json} = Native.translate(query, nil, nil, nil, "legacy")
      %{"read_model" => plan} = Jason.decode!(json)
      assert [%{"field" => ^field, "op" => "eq"}] = plan["filters"]
      matching = %{field => timestamp}

      assert [^matching] =
               FleetQuery.apply_plan([%{field => nil}, %{field => DateTime.shift(timestamp, second: -1)}, matching], plan)
    end
  end

  test "multiword plugin name builder filters translate and select the intended rows" do
    for name <- ["Example WASM Check", "Example\tWASM Check", ~s(Example "WASM" \\ Check)],
        op <- ~w(contains not_contains equals not_equals) do
      query =
        "plugin_fleet"
        |> Builder.default_state()
        |> Map.put("filters", [%{"field" => "plugin_name", "op" => op, "value" => name}])
        |> Builder.build()

      assert {:ok, json} = Native.translate(query, nil, nil, nil, "legacy")
      %{"read_model" => plan} = Jason.decode!(json)
      matching = %{"plugin_name" => name}
      containing = %{"plugin_name" => "Prefix #{name} suffix"}
      other = %{"plugin_name" => "Different check"}

      expected =
        case op do
          "contains" -> [matching, containing]
          "not_contains" -> [other]
          "equals" -> [matching]
          "not_equals" -> [containing, other]
        end

      assert FleetQuery.apply_plan([matching, containing, other], plan) == expected
    end
  end

  test "observed add-on builder filters translate with supported comparisons and values" do
    for entity <- ~w(addon_statuses addon_status),
        {field, value} <- [
          {"agent_uid", "agent-example"},
          {"addon_id", "example-check"},
          {"state", "unhealthy"},
          {"version", "1.2.3"},
          {"arch", "amd64"}
        ],
        op <- [Catalog.default_filter_op(entity, field), "contains", "not_contains", "equals", "not_equals"] do
      query =
        entity
        |> Builder.default_state()
        |> Map.put("filters", [%{"field" => field, "op" => op, "value" => value}])
        |> Builder.build()

      exact? = field in ~w(state arch) or op in ~w(equals not_equals)
      negated? = op in ~w(not_contains not_equals)
      expected_value = if exact?, do: value, else: "%#{value}%"

      operator =
        case {exact?, negated?} do
          {true, false} -> "="
          {true, true} -> "!="
          {false, false} -> "ILIKE"
          {false, true} -> "NOT ILIKE"
        end

      assert {:ok, json} = Native.translate(query, nil, nil, nil, "legacy")
      assert %{"sql" => sql, "params" => [%{"t" => "text", "v" => ^expected_value} | _]} = Jason.decode!(json)
      assert sql =~ ~s("#{field}" #{operator} $1)
    end
  end

  test "audit catalog advertises the browsing vocabulary without query navigation" do
    event = Catalog.entity("security_events")
    assert event.id == "security_events"
    assert Catalog.structured()["entities"]["security_events"]["route"] == nil
    assert Page.route_for_query("in:security_events severity:critical", "/devices") == "/devices"
    assert event.default_time == "last_24h"
    assert event.default_sort_field == "occurred_at"
    assert event.default_sort_dir == "desc"

    assert Catalog.structured()["entities"]["security_events"]["enums"] == %{
             "kind" => Enum.map(ServiceRadar.Security.SecurityEvent.kinds(), &to_string/1),
             "severity" => ["info", "warning", "critical"]
           }

    for field <- ["kind", "severity", "actor_id", "ip", "route", "correlation_id", "search"] do
      assert field in event.filter_fields
    end
  end

  test "every catalog entity other than dashboards has a permission mapping" do
    unmapped =
      Catalog.entities()
      |> Enum.map(& &1.id)
      |> Enum.reject(fn id ->
        id == "dashboards" or EntityAccess.permission_for_entity(id) != :passthrough
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
    {"identity_evidence_edges", ~w(identity_evidence_edges identity_evidence evidence_edges)},
    {"identity_decisions", ~w(identity_decisions identity_decision dire_decisions)},
    {"deduplication_tasks", ~w(deduplication_tasks deduplication_task dedup_tasks identity_deduplication_tasks)}
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
             EntityAccess.permission_for_entity("endpoint_vulnerability_assessments")

    assert EntityAccess.permission_for_entity("endpoint_vulnerability_matches") ==
             EntityAccess.permission_for_entity("endpoint_vulnerability_assessments")

    assert EntityAccess.permission_for_entity("package_vulnerabilities") ==
             EntityAccess.permission_for_entity("endpoint_vulnerability_assessments")

    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("cves")
    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("advisory_cpes")
    assert {:ok, "devices.view"} = EntityAccess.permission_for_entity("cve_matches")

    assert EntityAccess.permission_for_entity("ioc_matches") ==
             EntityAccess.permission_for_entity("threat_intel_matches")

    assert {:ok, "observability.netflow.view"} =
             EntityAccess.permission_for_entity("threat_intel_matches")

    # Camera inventory is gated like the /cameras page; an unmapped alias would
    # pass through to the SRQL compiler ungated.
    for alias <- ~w(camera_sources camera_source cameras camera) do
      assert {:ok, "devices.view"} = EntityAccess.permission_for_entity(alias)
    end

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

  # Regression for review round 1, Critical A: the Rust parser
  # (rust/srql/src/parser.rs) assigns `entity = Some(parse_entity(...))`
  # unconditionally on every `in` token it sees while tokenizing, so the LAST
  # `in:` token in the raw string is what actually executes. A gate that
  # resolves the FIRST `in:` token authorizes one entity while the compiler
  # executes a different one -- the gate and the compiler must agree on which
  # token wins, or the gate can be bypassed by appending a second `in:` token
  # naming a more sensitive entity.
  describe "extract_entity/1 resolves the LAST in: token, matching the Rust parser" do
    test "extract_entity/1 returns the last in: token" do
      assert EntityAccess.extract_entity("in:logs limit:1 in:merge_audit") == "merge_audit"
    end

    test "authorize/3 denies based on the entity the compiler will actually execute" do
      scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

      assert {:error, :forbidden} =
               EntityAccess.authorize("in:logs limit:1 in:merge_audit", scope)
    end
  end

  # Regression for review round 1, Critical B: `"in:" <> entity` is a
  # case-sensitive literal match, so `IN:devices` never matches it and falls
  # through to fallback_entity/1, which downcases the WHOLE token to the
  # literal "in:devices" (no colon-split), matches no permission, and
  # authorizes as :passthrough -- fully ungated. The Rust parser lowercases
  # the token's key (`raw_key.trim().to_lowercase()`) before comparing it to
  # "in", so `IN:devices` executes as Entity::Devices there.
  describe "extract_entity/1 case-insensitive in: key" do
    test "authorize/3 denies IN:devices and In:devices for a scope lacking devices.view" do
      scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

      assert {:error, :forbidden} = EntityAccess.authorize("IN:devices", scope)
      assert {:error, :forbidden} = EntityAccess.authorize("In:devices", scope)
    end
  end

  # Sweep diagnostics (issue 4167, task 7): these five entities were ungated
  # -- `permission_for_entity/1` fell through to `:passthrough` -- so any
  # authenticated caller could read sweep configuration, execution history,
  # and per-host results regardless of scope. Enumerate every parser alias
  # (rust/srql/src/parser/entity.rs), not just the canonical id, the same way
  # the identity-diagnostic aliases above are enumerated: a missing alias is
  # an ungated back door to an otherwise-gated entity.
  @sweep_diagnostic_aliases [
    {"sweep_groups", ~w(sweep_groups sweep_group sweeps)},
    {"sweep_profiles", ~w(sweep_profiles sweep_profile scanner_profiles scanner_profile)},
    {"sweep_executions", ~w(sweep_executions sweep_execution sweep_group_executions)},
    {"sweep_results", ~w(sweep_results sweep_result sweep_host_results)},
    {"sweep_coverage", ~w(sweep_coverage sweep_coverage_daily)},
    {"device_sweep_overlap", ~w(device_sweep_overlap sweep_overlap)}
  ]

  test "every sweep diagnostic alias is gated by networks.sweeps.view, never passthrough" do
    unmapped =
      for {_canonical, aliases} <- @sweep_diagnostic_aliases,
          entity <- aliases,
          EntityAccess.permission_for_entity(entity) != {:ok, "networks.sweeps.view"} do
        {entity, EntityAccess.permission_for_entity(entity)}
      end

    assert unmapped == [],
           "sweep diagnostic aliases missing from the RBAC map: #{inspect(unmapped)}"
  end

  test "every sweep diagnostic alias the RBAC map claims is accepted by the parser" do
    unsupported =
      for {_canonical, aliases} <- @sweep_diagnostic_aliases,
          entity <- aliases,
          not match?({:ok, _}, Native.parse_ast("in:#{entity} limit:1")) do
        entity
      end

    assert unsupported == []
  end

  # Proves the gate actually denies: before this task these five entities
  # (and every alias) were :passthrough, so this test must fail red against
  # the pre-fix code (no `networks.sweeps.view` mapping) and pass green once
  # the mapping exists.
  test "a caller without networks.sweeps.view is refused every sweep diagnostic entity and alias" do
    scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

    for {_canonical, aliases} <- @sweep_diagnostic_aliases,
        entity <- aliases do
      assert {:error, :forbidden} = EntityAccess.authorize("in:#{entity} limit:1", scope),
             "expected in:#{entity} to be forbidden without networks.sweeps.view"
    end
  end

  test "a caller with networks.sweeps.view is authorized for every sweep diagnostic entity" do
    scope = %Scope{user: nil, permissions: MapSet.new(["networks.sweeps.view"])}

    for {canonical, _aliases} <- @sweep_diagnostic_aliases do
      assert :ok = EntityAccess.authorize("in:#{canonical} limit:1", scope)
    end
  end

  describe "otel_services any-of gate" do
    # One catalog covers three signals, so the gate admits a caller holding any
    # one view permission and hands SRQL the signals it holds. Before this
    # mapping the entity was :passthrough -- ungated on the HTTP and MCP paths.
    defp signals_scope(permissions), do: %Scope{user: nil, permissions: MapSet.new(permissions)}

    test "returns exactly the signals the caller may view" do
      cases = [
        {["observability.logs.view"], ["logs"]},
        {["observability.traces.view", "observability.metrics.view"], ["traces", "metrics"]},
        {["observability.logs.view", "observability.traces.view", "observability.metrics.view"],
         ["logs", "traces", "metrics"]}
      ]

      for {permissions, signals} <- cases do
        assert {:ok, ^signals} =
                 EntityAccess.authorize_signals("in:otel_services limit:5", signals_scope(permissions))

        assert :ok = EntityAccess.authorize("in:otel_services limit:5", signals_scope(permissions))
      end
    end

    test "refuses a caller holding none of the three observability views" do
      scope = signals_scope(["devices.view", "observability.events.view"])

      assert {:error, :forbidden} = EntityAccess.authorize_signals("in:otel_services", scope)
      assert {:error, :forbidden} = EntityAccess.authorize("in:otel_services", scope)
    end

    test "a missing scope is forbidden, and optional_scope admits it with no permitted set" do
      assert {:error, :forbidden} = EntityAccess.authorize_signals("in:otel_services", nil)
      assert {:ok, nil} = EntityAccess.authorize_signals("in:otel_services", nil, optional_scope: true)
    end

    test "single-permission entities carry no permitted set" do
      scope = signals_scope(["observability.logs.view"])

      assert {:ok, nil} = EntityAccess.authorize_signals("in:logs", scope)
      assert {:error, :forbidden} = EntityAccess.authorize_signals("in:otel_traces", scope)
    end
  end
end
