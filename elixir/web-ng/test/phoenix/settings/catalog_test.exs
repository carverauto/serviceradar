defmodule ServiceRadarWebNGWeb.Settings.CatalogTest do
  @moduledoc """
  The anti-breakage gate for the Settings navigation catalog.

  This is a pure unit test (no database). It fails CI — never production —
  whenever the catalog is malformed: a misfiled category, an unknown permission
  key, a duplicate route or `(category, id)`, an ambiguous match prefix, or an
  orphaned `live_view` that no Phoenix route reaches.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.RBAC.Catalog, as: RBACCatalog
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.Settings.Catalog

  @moduletag :db_free

  describe "structural validation (the gate)" do
    test "every view.category exists in @categories" do
      category_ids = MapSet.new(Catalog.categories(), & &1.id)

      for view <- Catalog.views() do
        assert MapSet.member?(category_ids, view.category),
               "view #{inspect(view.id)} references unknown category #{inspect(view.category)}"
      end
    end

    test "every view.permission is a key in RBAC.Catalog.permission_keys/0" do
      permission_keys = MapSet.new(RBACCatalog.permission_keys())

      for view <- Catalog.views(), not is_nil(view.permission) do
        assert MapSet.member?(permission_keys, view.permission),
               "view #{inspect(view.id)} permission #{inspect(view.permission)} " <>
                 "is not in RBAC.Catalog.permission_keys/0"
      end
    end

    test "every category.permission (when set) is a key in RBAC.Catalog.permission_keys/0" do
      permission_keys = MapSet.new(RBACCatalog.permission_keys())

      for category <- Catalog.categories(), not is_nil(category.permission) do
        assert MapSet.member?(permission_keys, category.permission),
               "category #{inspect(category.id)} permission #{inspect(category.permission)} " <>
                 "is not in RBAC.Catalog.permission_keys/0"
      end
    end

    test "each route is unique" do
      routes = Enum.map(Catalog.views(), & &1.route)
      assert routes == Enum.uniq(routes), "duplicate routes: #{inspect(duplicates(routes))}"
    end

    test "each (category, id) pair is unique" do
      keys = Enum.map(Catalog.views(), &{&1.category, &1.id})
      assert keys == Enum.uniq(keys), "duplicate (category, id): #{inspect(duplicates(keys))}"
    end

    test "each view id is unique across the whole catalog" do
      ids = Enum.map(Catalog.views(), & &1.id)
      assert ids == Enum.uniq(ids), "duplicate view ids: #{inspect(duplicates(ids))}"
    end

    test "no two views share an identical match prefix (ambiguity guard)" do
      prefix_owners =
        Catalog.views()
        |> Enum.flat_map(fn view ->
          Enum.map(Catalog.match_prefixes(view), fn prefix -> {prefix, view.id} end)
        end)
        |> Enum.group_by(fn {prefix, _id} -> prefix end, fn {_prefix, id} -> id end)

      ambiguous =
        Enum.filter(prefix_owners, fn {_prefix, ids} -> ids |> Enum.uniq() |> length() > 1 end)

      assert ambiguous == [],
             "match prefixes owned by more than one view: #{inspect(ambiguous)}"
    end

    test "every view.live_view is reachable in the Phoenix router (orphan detector)" do
      routed = routed_live_views()

      for view <- Catalog.views() do
        modules = Map.get(routed, view.route, [])

        assert view.live_view in modules,
               "view #{inspect(view.id)} route #{inspect(view.route)} does not route to " <>
                 "#{inspect(view.live_view)} (router has: #{inspect(modules)})"
      end
    end
  end

  describe "view_for_path/1 (longest-prefix resolution)" do
    test "resolves an exact route" do
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events")
      assert %{id: :lockouts} = Catalog.view_for_path("/settings/audit/lockouts")
      assert %{id: :system_event_logs} = Catalog.view_for_path("/logs")
    end

    test "resolves a nested/child path to the owning view via prefix match" do
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events/abc-123")
      assert %{id: :system_event_logs} = Catalog.view_for_path("/logs/xyz")
    end

    test "ignores a trailing slash and query string" do
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events/")
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events?kind=csp")
    end

    test "does not false-match a sibling prefix" do
      # /settings/audit/eventsX must NOT match the /settings/audit/events prefix
      refute Catalog.view_for_path("/settings/audit/eventsomething")
    end

    test "returns nil for an unknown path" do
      refute Catalog.view_for_path("/nope")
      refute Catalog.view_for_path(nil)
    end

    test "shared /settings/networks root resolves via longest prefix" do
      # Sweep Profiles owns /settings/networks; BGP / BMP owns the longer child.
      assert %{id: :sweep_profiles} = Catalog.view_for_path("/settings/networks")
      assert %{id: :bmp} = Catalog.view_for_path("/settings/networks/bmp")
      assert %{id: :integrations} = Catalog.view_for_path("/settings/networks/integrations/new")
      assert %{id: :discovery_jobs} = Catalog.view_for_path("/settings/networks/discovery")
    end

    test "legacy /admin/* duplicate routes resolve to their canonical catalog view" do
      assert %{id: :cluster_status} = Catalog.view_for_path("/admin/cluster")
      assert %{id: :plugins} = Catalog.view_for_path("/admin/plugins")
      assert %{id: :addons} = Catalog.view_for_path("/admin/addons")
      assert %{id: :agent_deploy} = Catalog.view_for_path("/admin/edge-packages")
    end

    test "the add-on fleet child wins over the add-ons parent prefix" do
      assert %{id: :addons} = Catalog.view_for_path("/settings/agents/addons")
      assert %{id: :addon_fleet} = Catalog.view_for_path("/settings/agents/addons/fleet")
    end
  end

  describe "breadcrumbs_for_path/1" do
    test "returns Settings > Category > View for a known path, all crumbs navigable" do
      # "Settings" links to the default landing (first category's first view); the
      # category crumb links to that category's first view; the view crumb to itself.
      assert [
               %{label: "Settings", route: settings_route},
               %{label: "Audit & System Log", route: "/settings/audit/events"},
               %{label: "Audit Trail", route: "/settings/audit/events"}
             ] = Catalog.breadcrumbs_for_path("/settings/audit/events")

      assert settings_route == Catalog.settings_landing_route()
      assert is_binary(settings_route)
    end

    test "the root crumb for an unknown path still links to the settings landing" do
      assert [%{label: "Settings", route: route}] = Catalog.breadcrumbs_for_path("/nope")
      assert route == Catalog.settings_landing_route()
    end
  end

  describe "scope-aware visibility" do
    test "an auditor sees the audit views but not the logs-gated view" do
      scope = %Scope{permissions: MapSet.new(["settings.audit.view"])}

      visible = Catalog.visible_views(scope, :audit_system_log)
      ids = Enum.map(visible, & &1.id)

      assert :audit_trail in ids
      assert :lockouts in ids
      assert :history in ids
      refute :system_event_logs in ids

      assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == :audit_system_log))
    end

    test "a scope with the logs permission also sees System Event Logs" do
      scope =
        %Scope{permissions: MapSet.new(["settings.audit.view", "observability.logs.view"])}

      ids = scope |> Catalog.visible_views(:audit_system_log) |> Enum.map(& &1.id)
      assert :system_event_logs in ids
    end

    test "a scope with no permissions sees no gated category" do
      scope = %Scope{permissions: MapSet.new([])}

      category_ids = Enum.map(Catalog.visible_categories(scope), & &1.id)

      # No gated category is visible with an empty scope.
      refute :audit_system_log in category_ids
      refute :core_cluster in category_ids
      refute :discovery_sweeps in category_ids
      refute :edge_ops in category_ids
      refute :network_services in category_ids
      refute :mail_alerts in category_ids

      assert Catalog.visible_views(scope, :audit_system_log) == []
    end

    test "an authenticated scope always sees ungated personal views (orphan rescue)" do
      # `API Credentials` (and `Profile`, though nav-hidden) are per-user pages
      # with no permission gate, so Security & Auth is minimally visible even to a
      # scope with no RBAC permissions.
      scope = %Scope{permissions: MapSet.new([])}

      ids = scope |> Catalog.visible_views(:security_auth) |> Enum.map(& &1.id)
      assert :api_credentials in ids
      refute :profile in ids, "profile is hidden_from_nav and must not appear in nav lists"
      refute :auth_users in ids, "gated Security & Auth views stay hidden for an empty scope"

      assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == :security_auth))
    end

    test "each category is reachable by some permission set" do
      # Every category must own at least one view, and a scope holding that view's
      # permission must make the category visible. Guards against an empty category.
      for category <- Catalog.categories() do
        views = Catalog.views_for_category(category.id)
        assert views != [], "category #{inspect(category.id)} has no views"

        permission = Enum.find_value(views, & &1.permission)
        scope = %Scope{permissions: MapSet.new(List.wrap(permission))}

        assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == category.id)),
               "category #{inspect(category.id)} is not visible to any single-permission scope"
      end
    end

    test "a networks admin sees Discovery & Sweeps and Network Services" do
      scope = %Scope{permissions: MapSet.new(["settings.networks.manage"])}
      category_ids = Enum.map(Catalog.visible_categories(scope), & &1.id)

      assert :discovery_sweeps in category_ids
      assert :network_services in category_ids

      discovery_ids = scope |> Catalog.visible_views(:discovery_sweeps) |> Enum.map(& &1.id)
      assert :sweep_profiles in discovery_ids
      refute :snmp_profiles in discovery_ids, "SNMP needs its own permission"
    end

    test "an edge admin sees Edge Ops views" do
      scope = %Scope{permissions: MapSet.new(["settings.edge.manage"])}
      ids = scope |> Catalog.visible_views(:edge_ops) |> Enum.map(& &1.id)

      assert :agent_releases in ids
      assert :agent_deploy in ids
      refute :plugins in ids, "plugins needs plugins.view"
    end

    test "a cluster viewer sees Core Cluster / Cluster Status" do
      scope = %Scope{permissions: MapSet.new(["settings.view"])}
      ids = scope |> Catalog.visible_views(:core_cluster) |> Enum.map(& &1.id)

      assert :cluster_status in ids
      assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == :core_cluster))
    end

    test "palette_index/1 only includes permitted views and is well-shaped" do
      scope = %Scope{permissions: MapSet.new(["settings.audit.view"])}
      index = Catalog.palette_index(scope)

      assert Enum.all?(index, &Map.has_key?(&1, :route))
      assert Enum.all?(index, &Map.has_key?(&1, :view_title))
      assert Enum.any?(index, &(&1.id == :audit_trail))
      refute Enum.any?(index, &(&1.id == :system_event_logs))
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp routed_live_views do
    Router.__routes__()
    |> Enum.flat_map(fn route ->
      case route.metadata do
        %{phoenix_live_view: {module, _action, _opts, _extra}} -> [{route.path, module}]
        %{phoenix_live_view: {module, _action}} -> [{route.path, module}]
        _ -> []
      end
    end)
    |> Enum.group_by(fn {path, _module} -> path end, fn {_path, module} -> module end)
  end

  defp duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
