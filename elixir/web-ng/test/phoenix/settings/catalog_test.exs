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
    test "credential management copy covers both reusable credentials and rules" do
      credential_management = Catalog.view(:credential_rules)

      assert credential_management.title == "Credentials and Rules"
      assert credential_management.description =~ "reusable credentials"
      assert credential_management.description =~ "scoped rules"
    end

    test "Ansible copy exposes only supported settings workflows" do
      ansible = Catalog.view(:ansible)

      assert ansible.description == "Manage Ansible controllers and repositories."
      refute String.contains?(String.downcase(ansible.description), "schedule")
      refute String.contains?(String.downcase(ansible.description), "retention")
      refute "schedule" in ansible.keywords
      refute "retention" in ansible.keywords
    end

    test "every view.category exists in @categories" do
      category_ids = MapSet.new(Catalog.categories(), & &1.id)

      for view <- Catalog.views() do
        assert MapSet.member?(category_ids, view.category),
               "view #{inspect(view.id)} references unknown category #{inspect(view.category)}"
      end
    end

    test "every view.permission key is in RBAC.Catalog.permission_keys/0" do
      permission_keys = MapSet.new(RBACCatalog.permission_keys())

      for view <- Catalog.views(), not is_nil(view.permission) do
        for permission <- List.wrap(view.permission) do
          assert MapSet.member?(permission_keys, permission),
                 "view #{inspect(view.id)} permission #{inspect(permission)} " <>
                   "is not in RBAC.Catalog.permission_keys/0"
        end
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

    test "every declared view tab maps to a tab the LiveView handles and valid RBAC permissions" do
      permission_keys = MapSet.new(RBACCatalog.permission_keys())

      assert Map.get(Catalog.view(:sweep_profiles), :tabs, []) != []
      assert Map.get(Catalog.view(:ansible), :tabs, []) != []

      for view <- Catalog.views(), tab <- Map.get(view, :tabs, []) do
        assert Code.ensure_loaded?(view.live_view)

        assert function_exported?(view.live_view, :supported_tabs, 0),
               "view #{inspect(view.id)} declares tabs, so #{inspect(view.live_view)} must export supported_tabs/0"

        supported = view.live_view.supported_tabs()

        assert tab.tab in supported,
               "view #{inspect(view.id)} tab #{inspect(tab.tab)} is not in #{inspect(view.live_view)}.supported_tabs/0 (#{inspect(supported)})"

        assert tab.route in ["#{view.route}?tab=#{tab.tab}", "#{view.route}/#{tab.tab}"],
               "view #{inspect(view.id)} tab #{inspect(tab.id)} route #{inspect(tab.route)} must be " <>
                 "#{view.route}?tab=#{tab.tab} or #{view.route}/#{tab.tab}"

        for permission <- List.wrap(tab.permission) do
          assert MapSet.member?(permission_keys, permission),
                 "view #{inspect(view.id)} tab #{inspect(tab.id)} permission #{inspect(permission)} " <>
                   "is not in RBAC.Catalog.permission_keys/0"
        end
      end
    end
  end

  # The reverse of the orphan detector: the router is the list of Settings pages,
  # and search can only reach a page the catalog names.
  describe "router coverage (every Settings page is in the catalog)" do
    test "every Settings live route is a catalog view or a sub-page of one" do
      for {path, _module} <- settings_live_routes() do
        view = Catalog.view_for_path(path)

        assert view, "#{path} is routed, but no catalog view owns it: add it to Catalog @views"

        assert path in Catalog.match_prefixes(view) or sub_page?(path),
               "#{path} is a page of its own, but it reaches the catalog only through the prefix of " <>
                 "#{inspect(view.id)} (#{view.route}), so search cannot find it: give it a catalog view"
      end
    end

    test "a route whose tab is a path segment declares its tabs" do
      for {path, module} <- settings_live_routes(), String.ends_with?(path, "/:tab") do
        assert Code.ensure_loaded?(module) and function_exported?(module, :supported_tabs, 0),
               "#{path} takes its tab from the path, so #{inspect(module)} must export supported_tabs/0"
      end
    end

    test "every tab a Settings LiveView handles has a catalog sub-entry" do
      # One LiveView can back several views (Sweep Profiles and Discovery Jobs);
      # each tab needs a sub-entry under one of them.
      tabs_by_live_view =
        Enum.group_by(Catalog.views(), & &1.live_view, fn view ->
          view |> Map.get(:tabs, []) |> Enum.map(& &1.tab)
        end)

      for {live_view, catalog_tabs} <- tabs_by_live_view,
          Code.ensure_loaded?(live_view),
          function_exported?(live_view, :supported_tabs, 0),
          tab <- live_view.supported_tabs() do
        assert tab in List.flatten(catalog_tabs),
               "#{inspect(live_view)} handles tab #{inspect(tab)}, but no catalog view of it has a " <>
                 "tab sub-entry for it, so search cannot reach it"
      end

      for {path, module} <- settings_live_routes(), String.ends_with?(path, "/:tab") do
        view = Catalog.view_for_path(path)

        assert view && view.live_view == module,
               "#{path} routes to #{inspect(module)}, but the catalog view that owns it does not"
      end
    end

    test "every catalog view and tab route reaches its LiveView" do
      for view <- Catalog.views(), route <- [view.route | Enum.map(Map.get(view, :tabs, []), & &1.route)] do
        assert routed_live_view(route) == view.live_view,
               "catalog link #{route} (view #{inspect(view.id)}) does not route to #{inspect(view.live_view)}"
      end
    end
  end

  describe "view_for_path/1 (longest-prefix resolution)" do
    test "resolves an exact route" do
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events")
      assert %{id: :lockouts} = Catalog.view_for_path("/settings/audit/lockouts")
      assert %{id: :snmp_profiles} = Catalog.view_for_path("/settings/snmp")
    end

    test "resolves a nested/child path to the owning view via prefix match" do
      assert %{id: :audit_trail} = Catalog.view_for_path("/settings/audit/events/abc-123")
      assert %{id: :snmp_profiles} = Catalog.view_for_path("/settings/snmp/v3")
    end

    test "the dropped System Event Logs view no longer resolves (/logs is not a settings view)" do
      refute Catalog.view_for_path("/logs")
      refute Catalog.view_for_path("/logs/xyz")
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
      assert %{id: :edge_onboarding} = Catalog.view_for_path("/admin/edge-packages")
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
      # Audit Trail now lives under the System category (Security parent-group).
      assert [
               %{label: "Settings", route: settings_route},
               %{label: "System", route: "/settings/cluster"},
               %{label: "Audit Trail", route: "/settings/audit/events"}
             ] = Catalog.breadcrumbs_for_path("/settings/audit/events")

      assert settings_route == Catalog.settings_landing_route()
      assert settings_route == "/settings/cluster"
      assert is_binary(settings_route)
    end

    test "the root crumb for an unknown path still links to the settings landing" do
      assert [%{label: "Settings", route: route}] = Catalog.breadcrumbs_for_path("/nope")
      assert route == Catalog.settings_landing_route()
    end
  end

  describe "scope-aware visibility" do
    test "an auditor sees the audit views under System / Security" do
      scope = %Scope{permissions: MapSet.new(["settings.audit.view"])}

      visible = Catalog.visible_views(scope, :system)
      ids = Enum.map(visible, & &1.id)

      assert :audit_trail in ids
      assert :lockouts in ids
      assert :history in ids

      # All three audit views sit in the Security parent-group.
      for id <- [:audit_trail, :lockouts, :history] do
        assert Catalog.view(id).parent_group == :sys_security
      end

      assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == :system))
    end

    test "a scope with no permissions sees no fully-gated category" do
      scope = %Scope{permissions: MapSet.new([])}

      category_ids = Enum.map(Catalog.visible_categories(scope), & &1.id)

      # Every System / Network / Edge view is permission-gated (Profile is
      # nav-hidden), so an empty scope sees no settings category at all.
      refute :system in category_ids
      refute :network_services in category_ids
      refute :edge_ops in category_ids

      assert Catalog.visible_views(scope, :system) == []
      assert Catalog.visible_views(scope, :network_services) == []
      assert Catalog.visible_views(scope, :edge_ops) == []
    end

    test "API credentials and MCP sessions are gated on their catalog keys" do
      empty = %Scope{permissions: MapSet.new([])}
      empty_ids = empty |> Catalog.visible_views(:system) |> Enum.map(& &1.id)

      refute :api_credentials in empty_ids
      refute :mcp_sessions in empty_ids
      refute :profile in empty_ids, "profile is hidden_from_nav and must not appear in nav lists"

      creds = %Scope{permissions: MapSet.new(["settings.api_credentials.manage"])}
      assert :api_credentials in Enum.map(Catalog.visible_views(creds, :system), & &1.id)
      assert Enum.any?(Catalog.visible_categories(creds), &(&1.id == :system))

      mcp = %Scope{permissions: MapSet.new(["settings.mcp.manage"])}

      if ServiceRadarWebNGWeb.FeatureFlags.mcp_enabled?() do
        assert :mcp_sessions in Enum.map(Catalog.visible_views(mcp, :system), & &1.id)
      end
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

    test "a networks admin sees Network Services (Discovery + Services groups)" do
      scope = %Scope{permissions: MapSet.new(["settings.networks.manage"])}
      category_ids = Enum.map(Catalog.visible_categories(scope), & &1.id)

      assert :network_services in category_ids

      ids = scope |> Catalog.visible_views(:network_services) |> Enum.map(& &1.id)
      assert :sweep_profiles in ids
      assert :bmp in ids
      refute :snmp_profiles in ids, "SNMP needs its own permission"

      # The scoped nav tree exposes both parent-groups.
      group_ids = scope |> Catalog.nav_tree(:network_services) |> Enum.map(& &1.group.id)
      assert :net_discovery in group_ids
      assert :net_services in group_ids
    end

    test "Settings Rules is hidden from rule viewers who cannot author them" do
      # observability.rules.view is the product-surface permission (alert/rule
      # definitions on device pages). The Settings -> Alerts -> Rules editor
      # requires create or update; a custom profile such as demo that only
      # grants view must not see the Alerts settings group at all.
      viewer = %Scope{permissions: MapSet.new(["observability.rules.view"])}
      refute :rules in Enum.map(Catalog.visible_views(viewer, :system), & &1.id)

      refute Enum.any?(Catalog.nav_tree(viewer, :system), fn group ->
               group.group.id == :sys_alerts
             end)

      for permission <- ["observability.rules.update", "observability.rules.create"] do
        scope = %Scope{permissions: MapSet.new([permission])}
        assert :rules in Enum.map(Catalog.visible_views(scope, :system), & &1.id)
      end
    end

    test "an edge admin sees Edge Ops views" do
      scope = %Scope{permissions: MapSet.new(["settings.edge.manage"])}
      ids = scope |> Catalog.visible_views(:edge_ops) |> Enum.map(& &1.id)

      assert :agent_releases in ids
      assert :agent_deploy in ids
      refute :plugins in ids, "plugins needs plugins.view"
    end

    test "either retained Ansible management permission exposes catalog navigation" do
      for permission <- ["ansible.controllers.manage", "ansible.repositories.manage"] do
        scope = %Scope{permissions: MapSet.new([permission])}

        assert :ansible in Enum.map(Catalog.visible_views(scope, :edge_ops), & &1.id)

        assert Enum.any?(Catalog.nav_tree(scope, :edge_ops), fn group ->
                 Enum.any?(group.sections, fn section ->
                   Enum.any?(section.views, &(&1.id == :ansible))
                 end)
               end)

        assert Enum.any?(Catalog.palette_index(scope), &(&1.id == :ansible))
        assert Catalog.category_landing_route(scope, :edge_ops) == "/settings/ansible"

        assert [_, %{label: "Edge Ops", route: "/settings/ansible"}, _] =
                 Catalog.breadcrumbs_for_path("/settings/ansible", scope)
      end

      schedule_scope = %Scope{permissions: MapSet.new(["ansible.schedules.manage"])}
      refute :ansible in Enum.map(Catalog.visible_views(schedule_scope, :edge_ops), & &1.id)
      refute Enum.any?(Catalog.palette_index(schedule_scope), &(&1.id == :ansible))
    end

    test "a cluster viewer sees System / Cluster Status" do
      scope = %Scope{permissions: MapSet.new(["settings.view"])}
      ids = scope |> Catalog.visible_views(:system) |> Enum.map(& &1.id)

      assert :cluster_status in ids
      assert Catalog.view(:cluster_status).parent_group == :sys_cluster
      assert Enum.any?(Catalog.visible_categories(scope), &(&1.id == :system))
    end

    test "Authorization is gated on settings.auth.manage, not settings.view" do
      assert Catalog.view(:authorization_mappings).permission == "settings.auth.manage"

      operator = %Scope{permissions: MapSet.new(["settings.view"])}
      operator_ids = operator |> Catalog.visible_views(:system) |> Enum.map(& &1.id)
      refute :authorization_mappings in operator_ids
      refute :auth_users in operator_ids
      refute :authentication in operator_ids

      admin = %Scope{permissions: MapSet.new(["settings.auth.manage"])}
      admin_ids = admin |> Catalog.visible_views(:system) |> Enum.map(& &1.id)
      assert :authorization_mappings in admin_ids
      assert :auth_users in admin_ids
      assert :authentication in admin_ids
    end

    test "palette_index/1 only includes permitted views and is well-shaped" do
      scope = %Scope{permissions: MapSet.new(["settings.audit.view"])}
      index = Catalog.palette_index(scope)

      assert Enum.all?(index, &Map.has_key?(&1, :route))
      assert Enum.all?(index, &Map.has_key?(&1, :view_title))
      assert Enum.all?(index, &Map.has_key?(&1, :description))
      assert Enum.any?(index, &(&1.id == :audit_trail))
    end

    test "palette_index/1 and visible_tabs/2 index Sweep Profiles and Ansible tabs with RBAC filtering" do
      networks_scope = %Scope{permissions: MapSet.new(["settings.networks.manage"])}
      palette = Catalog.palette_index(networks_scope)

      for {tab_title, route} <- [
            {"Sweep Profiles › Sweep Groups", "/settings/networks?tab=groups"},
            {"Sweep Profiles › Scanner Profiles", "/settings/networks?tab=profiles"},
            {"Sweep Profiles › Active Scans", "/settings/networks?tab=active_scans"},
            {"Inventory Cleanup", "/settings/networks/inventory-cleanup"}
          ] do
        assert Enum.any?(palette, &(&1.view_title == tab_title and &1.route == route)),
               "expected #{tab_title} (#{route}) in palette_index"
      end

      cleanup_entry = Enum.find(palette, &(&1.route == "/settings/networks/inventory-cleanup"))
      assert "inventory" in cleanup_entry.keywords
      assert "cleanup" in cleanup_entry.keywords

      discovery_entry = Enum.find(palette, &(&1.route == "/settings/networks/discovery"))
      assert discovery_entry.view_title == "Discovery Jobs"
      assert "discovery" in discovery_entry.keywords

      repo_only_scope = %Scope{permissions: MapSet.new(["ansible.repositories.manage"])}
      repo_palette = Catalog.palette_index(repo_only_scope)

      assert Enum.any?(
               repo_palette,
               &(&1.view_title == "Ansible › Repositories" and
                   &1.route == "/settings/ansible?tab=repositories")
             )

      refute Enum.any?(repo_palette, &(&1.route == "/settings/ansible?tab=controllers"))

      ctrl_only_scope = %Scope{permissions: MapSet.new(["ansible.controllers.manage"])}
      ctrl_palette = Catalog.palette_index(ctrl_only_scope)

      assert Enum.any?(
               ctrl_palette,
               &(&1.view_title == "Ansible › Controllers" and
                   &1.route == "/settings/ansible?tab=controllers")
             )

      refute Enum.any?(ctrl_palette, &(&1.route == "/settings/ansible?tab=repositories"))
    end
  end

  describe "2-level tree model" do
    test "there are exactly three categories: System, Network Services, Edge Ops" do
      titles = Catalog.categories() |> Enum.sort_by(& &1.order) |> Enum.map(& &1.title)
      assert titles == ["System", "Network Services", "Edge Ops"]
    end

    test "every view.parent_group exists and belongs to the same category" do
      groups = Map.new(Catalog.parent_groups(), &{&1.id, &1})

      for view <- Catalog.views() do
        group = Map.get(groups, view.parent_group)

        assert group,
               "view #{inspect(view.id)} references unknown parent_group #{inspect(view.parent_group)}"

        assert group.category == view.category,
               "view #{inspect(view.id)} (category #{inspect(view.category)}) is filed under " <>
                 "parent_group #{inspect(view.parent_group)} which belongs to #{inspect(group.category)}"
      end
    end

    test "every parent_group.category exists in @categories" do
      category_ids = MapSet.new(Catalog.categories(), & &1.id)

      for group <- Catalog.parent_groups() do
        assert MapSet.member?(category_ids, group.category),
               "parent_group #{inspect(group.id)} references unknown category #{inspect(group.category)}"
      end
    end

    test "every view carries a boolean has_own_stats and a non-empty description" do
      for view <- Catalog.views() do
        assert is_boolean(view.has_own_stats),
               "view #{inspect(view.id)} has_own_stats must be boolean"

        assert is_binary(view.description) and view.description != "",
               "view #{inspect(view.id)} must have a non-empty description"
      end
    end

    test "Cluster Status is the only view flagged has_own_stats (renders its own metrics)" do
      own_stats = Catalog.views() |> Enum.filter(& &1.has_own_stats) |> Enum.map(& &1.id)
      assert own_stats == [:cluster_status]
    end

    test "the dropped System Event Logs view is gone and no view routes to /logs" do
      refute Enum.any?(Catalog.views(), &(&1.id == :system_event_logs))
      refute Enum.any?(Catalog.views(), &(&1.route == "/logs"))
    end

    test "nav_tree/2 returns groups with subgroup-chunked sections" do
      # An admin-ish scope that can see the whole Security parent-group.
      scope =
        %Scope{
          permissions:
            MapSet.new([
              "settings.auth.manage",
              "settings.audit.view",
              "identity.user_groups.manage"
            ])
        }

      tree = Catalog.nav_tree(scope, :system)
      security = Enum.find(tree, &(&1.group.id == :sys_security))

      assert security, "Security parent-group should be present"
      subgroups = Enum.map(security.sections, & &1.subgroup)
      assert "Users & Access" in subgroups

      # Every section is a %{subgroup, views} shape with a contiguous view run.
      for section <- security.sections do
        assert Map.has_key?(section, :subgroup)
        assert is_list(section.views) and section.views != []
      end
    end

    test "siblings/2 returns the active view's parent-group peers" do
      scope = %Scope{permissions: MapSet.new(["settings.audit.view"])}
      sibling_ids = scope |> Catalog.siblings(Catalog.view(:audit_trail)) |> Enum.map(& &1.id)

      assert :lockouts in sibling_ids
      assert :history in sibling_ids
      assert :audit_trail in sibling_ids
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

  # Live routes of the Settings pages: `/settings/**` and the legacy `/admin/*`
  # pages the catalog still owns. Oban Web's dashboard under /admin is not ours.
  defp settings_live_routes do
    for route <- Router.__routes__(),
        {module, _} <- [live_view(route)],
        String.starts_with?(route.path, ["/settings", "/admin/"]),
        String.starts_with?(Atom.to_string(module), "Elixir.ServiceRadarWebNGWeb.") do
      {route.path, module}
    end
  end

  defp live_view(%{metadata: %{phoenix_live_view: {module, action, _opts, _extra}}}), do: {module, action}
  defp live_view(%{metadata: %{phoenix_live_view: {module, action}}}), do: {module, action}
  defp live_view(_route), do: nil

  # A detail page or a form of the view it resolves to (`/:id`, `/new`, `/:id/edit`).
  defp sub_page?(path) do
    segments = String.split(path, "/", trim: true)
    Enum.any?(segments, &String.starts_with?(&1, ":")) or List.last(segments) in ["new", "edit"]
  end

  defp routed_live_view(route) do
    case Phoenix.Router.route_info(Router, "GET", URI.parse(route).path, "localhost") do
      %{phoenix_live_view: {module, _action, _opts, _extra}} -> module
      %{phoenix_live_view: {module, _action}} -> module
      _ -> nil
    end
  end

  defp duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
