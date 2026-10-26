defmodule ServiceRadarWebNGWeb.Settings.ShellTest do
  @moduledoc """
  DB-free render tests for the catalog-driven Settings shell.
  """

  # async: false because we start the (globally-named) Endpoint so that the
  # `~p` verified routes in the rendered components resolve without the full
  # application (and its database) running.
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Settings.AnsibleLive
  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index
  alias ServiceRadarWebNGWeb.Settings.Shell
  alias ServiceRadarWebNGWeb.Settings.StatusCards

  @moduletag :db_free

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    :ok
  end

  defp auditor_scope, do: %Scope{permissions: MapSet.new(["settings.audit.view"])}

  defp search_hit?(item, attribute, tokens) do
    [haystack] = LazyHTML.attribute(item, attribute)
    Enum.all?(tokens, &String.contains?(haystack, &1))
  end

  defp links_to_inventory_cleanup?(item) do
    link = LazyHTML.query(item, ~s(a[href="/settings/networks/inventory-cleanup"]))
    LazyHTML.text(link) =~ "Inventory Cleanup"
  end

  defp catalog_assigns(path) do
    scope = auditor_scope()
    view = Catalog.view_for_path(path)
    category = Catalog.category_for_view(view)

    %{
      current_path: path,
      current_scope: scope,
      active_view: view,
      active_category: category,
      breadcrumbs: Catalog.breadcrumbs_for_path(path),
      nav_tree: %{
        categories: Catalog.visible_categories(scope),
        groups: Catalog.nav_tree(scope, category.id)
      },
      palette: Catalog.palette_index(scope),
      stats: StatusCards.for_view(view)
    }
  end

  test "catalog chrome renders the new shell surfaces from the catalog" do
    assigns = catalog_assigns("/settings/audit/events")

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
      >
        <p data-test="page-body">audit events body</p>
      </Shell.settings_chrome>
      """)

    # View tree (parent-group + subgroup + leaves) + category switcher come from
    # the catalog. Audit Trail sits under System → Security → Users & Access.
    assert html =~ "Audit Trail"
    assert html =~ "System"
    assert html =~ "Security"
    assert html =~ "Users &amp; Access"
    assert html =~ "Lockouts"
    # Ctrl+K command palette dialog is present.
    assert html =~ ~s(id="settings-command-palette")
    assert html =~ "CommandPalette"
    # The page body is rendered in the content slot.
    assert html =~ ~s(data-test="page-body")
    # The dropped System Event Logs view is gone from the catalog entirely.
    refute html =~ "System Event Logs"
  end

  test "catalog links use ordinary navigation across LiveView session boundaries" do
    assigns = catalog_assigns("/admin/edge-packages")

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
      >
        <p>edge packages</p>
      </Shell.settings_chrome>
      """)

    history_link =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(a[href="/settings/audit/history"]))

    assert LazyHTML.text(history_link) =~ "History"
    assert LazyHTML.attribute(history_link, "data-phx-link") == []
  end

  test "catalog shell renders the phase-3 surfaces (header, search, status, palette)" do
    assigns = catalog_assigns("/settings/audit/events")

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
      >
        <p data-test="page-body">audit events body</p>
      </Shell.settings_chrome>
      """)

    # Header branding + the Ctrl+K palette trigger.
    assert html =~ "Settings Console"
    assert html =~ "data-command-palette-open"
    assert html =~ "Press Ctrl+K to jump anywhere"

    # The "Portal State" indicator was removed to give the tabs room for full labels.
    refute html =~ "Portal State"

    # Mobile off-canvas drawer: a peer checkbox + hamburger/backdrop toggle labels.
    assert html =~ ~s(id="settings-nav-drawer")
    assert html =~ "Open settings navigation"

    # Left panel collapsible tree: the "Search views…" filter + the tree hook +
    # native <details> parent-groups with a chevron affordance.
    assert html =~ "SettingsNavTree"
    assert html =~ "Search views"
    assert html =~ "data-nav-group"

    # Leaf view items must NOT render an expand chevron (only parent-groups do,
    # via hero-chevron-down on the <details> summary).
    refute html =~ "hero-chevron-right"

    # Contextual status-card strip: on an audit page the cards are the AUDIT set
    # (never cluster-health), each degrading to an em dash with no data source.
    # They render as a card grid, not a stacked daisyUI stats bar.
    assert html =~ "Audit events (24h)"
    assert html =~ "Config changes"
    assert html =~ ~s(data-settings-status-cards)
    assert html =~ ~s(class="card )
    refute html =~ "Cluster health"
    refute html =~ "stats-vertical"

    # Command palette rows surface the per-view description + section header.
    assert html =~ "Settings &amp; Deep Sections"
    assert html =~ "Browse stateless security events and audit entries."

    # The final breadcrumb is a "Navigate Views" sibling jumper (keeps its ▾ dropdown).
    assert html =~ "Navigate Views"
    assert html =~ "hero-chevron-down"

    # No leftover second icon rail: the shell must not render `.sr-ops-sidebar`.
    refute html =~ "sr-ops-sidebar"
  end

  test "the active view's parent-group is force-open and flagged for the deep-link reveal" do
    # A broad scope so more than one System parent-group renders, letting us
    # assert the active group differs from an inactive sibling.
    scope = %Scope{permissions: MapSet.new(["settings.audit.view", "settings.view"])}
    view = Catalog.view_for_path("/settings/audit/events")
    category = Catalog.category_for_view(view)

    assigns = %{
      scope: scope,
      view: view,
      category: category,
      breadcrumbs: Catalog.breadcrumbs_for_path("/settings/audit/events"),
      nav_tree: %{
        categories: Catalog.visible_categories(scope),
        groups: Catalog.nav_tree(scope, category.id)
      },
      stats: StatusCards.for_view(view)
    }

    html =
      rendered_to_string(~H"""
      <Shell.settings_shell
        current_path="/settings/audit/events"
        current_scope={@scope}
        active_view={@view}
        active_category={@category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={[]}
        stats={@stats}
      >
        <p>audit body</p>
      </Shell.settings_shell>
      """)

    # Audit Trail lives under System → Security: that group renders `open` AND
    # carries `data-active-group` so a deep-link expands it to reveal the leaf.
    assert html =~ ~r/data-group-id="sys_security"[^>]*data-active-group[^>]*open/
    # A visible but inactive sibling group (Cluster, via settings.view) is neither
    # flagged nor force-open.
    assert html =~ ~s(data-group-id="sys_cluster")
    refute html =~ ~r/data-group-id="sys_cluster"[^>]*data-active-group/
  end

  test "a status card with a :navigate destination renders a link; a plain card does not" do
    assigns = %{
      stats: [
        %{title: "API keys", value: 3, navigate: "/settings/api-credentials"},
        %{title: "Uptime", value: 42}
      ]
    }

    html =
      rendered_to_string(~H"""
      <Shell.settings_shell
        current_path="/settings/profile"
        current_scope={%Scope{permissions: MapSet.new([])}}
        active_view={nil}
        active_category={nil}
        breadcrumbs={[]}
        nav_tree={%{categories: [], groups: []}}
        palette={[]}
        stats={@stats}
      >
        <p>profile body</p>
      </Shell.settings_shell>
      """)

    # The card carrying a `:navigate` destination is wrapped in a link to the
    # managing page, with a hover affordance (the arrow icon), and still shows
    # its title + value.
    assert html =~ ~s(href="/settings/api-credentials")

    assert html =~ "API keys"
    assert html =~ "hero-arrow-up-right"
    assert html =~ "Uptime"
    assert html =~ ~s(data-settings-status-cards)

    # Precise structural check: the linked card is an <a class="card">, the
    # plain card a <div class="card">.
    doc = LazyHTML.from_fragment(html)
    linked = LazyHTML.query(doc, ~s(a.card[href="/settings/api-credentials"]))
    assert LazyHTML.text(linked) =~ "API keys"
    assert linked |> LazyHTML.attribute("class") |> List.first() =~ "cursor-pointer"

    plain = LazyHTML.query(doc, "[data-settings-status-cards] div.card")
    assert LazyHTML.text(plain) =~ "Uptime"
  end

  test "the profile (users) status cards carry per-resource navigate destinations" do
    # `for_view/1`'s metric resolvers fail soft to nil without a DB, but each
    # card's `:title`/`:navigate` are literals, so this stays DB-free.
    cards = StatusCards.for_view(Catalog.view(:profile))
    nav_by_title = Map.new(cards, fn card -> {card.title, Map.get(card, :navigate)} end)

    assert nav_by_title["Total users"] == "/settings/auth/users"
    assert nav_by_title["Active (30d)"] == "/settings/auth/users"
    assert nav_by_title["Admins"] == "/settings/auth/users"
    assert nav_by_title["API keys"] == "/settings/api-credentials"
  end

  test "edge status cards report the deployed ServiceRadar image version" do
    previous = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.23")

    on_exit(fn ->
      if previous,
        do: System.put_env("SERVICERADAR_RELEASE_VERSION", previous),
        else: System.delete_env("SERVICERADAR_RELEASE_VERSION")
    end)

    cards = StatusCards.for_view(Catalog.view(:plugins))
    assert Enum.find(cards, &(&1.title == "Latest release")).value == "1.4.23"
  end

  test "status strip is suppressed on a has_own_stats page (Cluster Status)" do
    # Cluster Status renders its own Oban metrics, so `for_view/1` returns
    # :suppressed and the shared strip must not render.
    view = Catalog.view(:cluster_status)
    assert StatusCards.for_view(view) == :suppressed

    assigns = %{stats: :suppressed}

    html =
      rendered_to_string(~H"""
      <div>
        <Shell.settings_shell
          current_path="/settings/cluster"
          current_scope={%Scope{permissions: MapSet.new(["settings.view"])}}
          active_view={ServiceRadarWebNGWeb.Settings.Catalog.view(:cluster_status)}
          active_category={ServiceRadarWebNGWeb.Settings.Catalog.category(:system)}
          breadcrumbs={ServiceRadarWebNGWeb.Settings.Catalog.breadcrumbs_for_path("/settings/cluster")}
          nav_tree={%{categories: [], groups: []}}
          palette={[]}
          stats={@stats}
        >
          <p>cluster body</p>
        </Shell.settings_shell>
      </div>
      """)

    refute html =~ "Cluster health"
    refute html =~ ~s(data-settings-status-cards)
  end

  describe "pending-approval badges" do
    # A staged package is inert -- it ships nothing and reconciles nothing -- but
    # the only signal was a per-row badge on a page you had to already be on. On
    # demo twelve add-on packages sat staged for up to seven weeks before anyone
    # noticed. The catalog cannot carry the count (it is a compile-time list and
    # the count is scoped and runtime), so ShellHook decorates the tree the
    # catalog produces. These pin that the shell actually renders what is put
    # there, and that a view without a count keeps the catalog's nil.

    defp badge_assigns(path, badges) do
      scope = %Scope{permissions: MapSet.new(["plugins.view", "settings.audit.view"])}
      view = Catalog.view_for_path(path)
      category = Catalog.category_for_view(view)

      groups =
        scope
        |> Catalog.nav_tree(category.id)
        |> Enum.map(fn group ->
          Map.update!(group, :sections, fn sections ->
            Enum.map(sections, fn section ->
              Map.update!(section, :views, fn views ->
                Enum.map(views, fn v ->
                  case Map.get(badges, v.id) do
                    nil -> v
                    count -> Map.put(v, :badge, count)
                  end
                end)
              end)
            end)
          end)
        end)

      %{
        current_path: path,
        current_scope: scope,
        active_view: view,
        active_category: category,
        breadcrumbs: Catalog.breadcrumbs_for_path(path),
        nav_tree: %{categories: Catalog.visible_categories(scope), groups: groups},
        palette: Catalog.palette_index(scope),
        stats: StatusCards.for_view(view)
      }
    end

    defp render_shell(assigns) do
      rendered_to_string(~H"""
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
      >
        <p>body</p>
      </Shell.settings_chrome>
      """)
    end

    # Assert on the badge element, not a bare digit -- the chrome is full of
    # incidental numbers (size-7, py-2, ring offsets), so `html =~ "7"` passes
    # on an undecorated render and proves nothing.
    defp badge_counts(html) do
      ~r/ml-auto[^>]*>\s*(\d+)\s*</ |> Regex.scan(html) |> Enum.map(&List.last/1)
    end

    test "a decorated view renders its count in the nav" do
      html = "/settings/agents/addons" |> badge_assigns(%{addons: 12}) |> render_shell()

      assert "12" in badge_counts(html)
    end

    test "an undecorated tree renders no badge at all" do
      html = "/settings/agents/addons" |> badge_assigns(%{}) |> render_shell()

      assert badge_counts(html) == []
    end

    test "only the counted view is badged" do
      html = "/settings/agents/addons" |> badge_assigns(%{addons: 3}) |> render_shell()

      assert badge_counts(html) == ["3"]
    end
  end

  describe "in-page tab search and deep links (#5554)" do
    test "command palette and view-tree search find Inventory Cleanup by the names of its settings" do
      scope = %Scope{permissions: MapSet.new(["settings.networks.manage"])}
      view = Catalog.view_for_path("/settings/networks")
      category = Catalog.category_for_view(view)

      assigns = %{
        current_path: "/settings/networks",
        current_scope: scope,
        active_view: view,
        active_category: category,
        breadcrumbs: Catalog.breadcrumbs_for_path("/settings/networks", scope),
        nav_tree: %{
          categories: Catalog.visible_categories(scope),
          groups: Catalog.nav_tree(scope, category.id)
        },
        palette: Catalog.palette_index(scope),
        stats: StatusCards.for_view(view)
      }

      html =
        rendered_to_string(~H"""
        <Shell.settings_chrome
          current_path={@current_path}
          current_scope={@current_scope}
          active_view={@active_view}
          active_category={@active_category}
          breadcrumbs={@breadcrumbs}
          nav_tree={@nav_tree}
          palette={@palette}
          stats={@stats}
        >
          <p>networks body</p>
        </Shell.settings_chrome>
        """)

      doc = LazyHTML.from_fragment(html)

      # What an operator types after reading a refused-pass log line or the page's
      # checkboxes. Both searches require every typed word, in any order.
      for query <- [
            "inventory cleanup",
            "device cleanup",
            "retirement",
            "retired",
            "override",
            "retirement override",
            "guard",
            "awx",
            "armis",
            "grace",
            "ephemeral",
            "expiry",
            "ephemeral expiry",
            "purge"
          ] do
        tokens = String.split(query)

        palette_hits =
          doc
          |> LazyHTML.query("[data-command-palette-item]")
          |> Enum.filter(&search_hit?(&1, "data-search", tokens))

        assert Enum.any?(palette_hits, &links_to_inventory_cleanup?/1),
               "palette query #{inspect(query)} does not find Inventory Cleanup"

        tree_hits =
          doc
          |> LazyHTML.query("#settings-view-tree [data-view-search]")
          |> Enum.filter(&search_hit?(&1, "data-view-search", tokens))

        assert Enum.any?(tree_hits, &links_to_inventory_cleanup?/1),
               "view-tree query #{inspect(query)} does not find Inventory Cleanup"
      end
    end

    test "NetworksLive.Index reads ?tab= in handle_params, renders the tab, and patches URL on switch_tab" do
      scope = %Scope{
        user: %{email: "admin@example.com", timezone: "Etc/UTC"},
        permissions: MapSet.new(["settings.networks.manage"])
      }

      view = Catalog.view_for_path("/settings/networks")
      category = Catalog.category_for_view(view)

      base_socket = %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        router: ServiceRadarWebNGWeb.Router,
        assigns: %{
          __changed__: %{},
          flash: %{},
          live_action: :index,
          current_scope: scope,
          current_path: "/settings/networks",
          page_title: "Network Sweeps",
          active_tab: :groups,
          sweep_groups: [],
          sweep_group_summary_agents: %{},
          sweep_profiles: [],
          running_executions: [],
          recent_executions: [],
          execution_progress: %{},
          mtr_running: [],
          mtr_recent: [],
          can_view_mtr_jobs: false,
          active_scans_filter: :all,
          mtr_refresh_pending: false,
          selected_group: nil,
          selected_profile: nil,
          show_form: nil,
          ash_form: nil,
          form: nil,
          target_device_count: nil,
          builder_open: false,
          builder: %{},
          builder_sync: true,
          last_target_query: nil,
          show_mapper_form: nil,
          mapper_jobs: [],
          mapper_agents: [],
          agent_picker: %{},
          agent_picker_open: false,
          agent_picker_selected_rows: [],
          agent_picker_summary_agent: nil,
          can_manage_networks: true,
          can_run_sweeps: true,
          mapper_job: nil,
          mapper_form: nil,
          mapper_seeds_text: "",
          mapper_unifi_form: nil,
          mapper_unifi_present: false,
          mapper_mikrotik_form: nil,
          mapper_mikrotik_present: false,
          mapper_mikrotik: %{},
          mapper_command_statuses: %{},
          sweep_command_statuses: %{},
          can_enable_banner_grab: false,
          banner_preview_device_count: nil,
          settings_active_view: view,
          settings_active_category: category,
          settings_breadcrumbs: Catalog.breadcrumbs_for_path("/settings/networks", scope),
          settings_nav_tree: %{
            categories: Catalog.visible_categories(scope),
            groups: Catalog.nav_tree(scope, category.id)
          },
          settings_palette: Catalog.palette_index(scope),
          settings_stats: []
        },
        private: %{live_temp: %{}, lifecycle: %Lifecycle{}}
      }

      assert {:noreply, profiles_socket} =
               Index.handle_params(
                 %{"tab" => "profiles"},
                 "http://localhost/settings/networks?tab=profiles",
                 base_socket
               )

      assert profiles_socket.assigns.active_tab == :profiles

      html =
        profiles_socket.assigns
        |> Index.render()
        |> rendered_to_string()

      assert html =~ "profile(s) available"

      assert {:noreply, fallback_socket} =
               Index.handle_params(
                 %{"tab" => "bogus"},
                 "http://localhost/settings/networks?tab=bogus",
                 profiles_socket
               )

      assert fallback_socket.assigns.active_tab == :groups

      assert {:noreply, patched_socket} =
               Index.handle_event(
                 "switch_tab",
                 %{"tab" => "profiles"},
                 fallback_socket
               )

      assert patched_socket.assigns.active_tab == :profiles

      assert patched_socket.redirected ==
               {:live, :patch, %{kind: :push, to: "/settings/networks?tab=profiles"}}
    end

    test "AnsibleLive reads ?tab= in handle_params with permission gating" do
      both_scope = %Scope{
        user: %{email: "admin@example.com", timezone: "Etc/UTC"},
        permissions: MapSet.new(["ansible.controllers.manage", "ansible.repositories.manage"])
      }

      disconnected_socket = %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        router: ServiceRadarWebNGWeb.Router,
        assigns: %{__changed__: %{}, current_scope: both_scope},
        private: %{live_temp: %{}, lifecycle: %Lifecycle{}}
      }

      assert {:ok, mounted_socket} =
               AnsibleLive.mount(%{}, %{}, disconnected_socket)

      assert {:noreply, repo_socket} =
               AnsibleLive.handle_params(
                 %{"tab" => "repositories"},
                 "http://localhost/settings/ansible?tab=repositories",
                 mounted_socket
               )

      assert repo_socket.assigns.active_tab == :repositories

      assert {:noreply, fallback_socket} =
               AnsibleLive.handle_params(
                 %{"tab" => "unknown"},
                 "http://localhost/settings/ansible?tab=unknown",
                 repo_socket
               )

      assert fallback_socket.assigns.active_tab == :controllers

      ctrl_only_scope = %Scope{
        user: %{email: "ctrl@example.com", timezone: "Etc/UTC"},
        permissions: MapSet.new(["ansible.controllers.manage"])
      }

      {:ok, ctrl_only_socket} =
        AnsibleLive.mount(%{}, %{}, %{
          disconnected_socket
          | assigns: %{__changed__: %{}, current_scope: ctrl_only_scope}
        })

      assert {:noreply, gated_socket} =
               AnsibleLive.handle_params(
                 %{"tab" => "repositories"},
                 "http://localhost/settings/ansible?tab=repositories",
                 ctrl_only_socket
               )

      assert gated_socket.assigns.active_tab == :controllers
    end
  end
end
