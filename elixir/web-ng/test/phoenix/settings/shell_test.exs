defmodule ServiceRadarWebNGWeb.Settings.ShellTest do
  @moduledoc """
  DB-free render tests for the catalog-driven Settings shell and the
  Original-UI toggle branch in `settings_chrome/1`.
  """

  # async: false because we start the (globally-named) Endpoint so that the
  # `~p` verified routes in the rendered components resolve without the full
  # application (and its database) running.
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Settings.Catalog
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

  defp catalog_assigns(path) do
    scope = auditor_scope()
    view = Catalog.view_for_path(path)
    category = Catalog.category_for_view(view)

    %{
      settings_ui: :catalog,
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
      stats: StatusCards.for_view(view),
      legacy_subnav: :none
    }
  end

  test "catalog chrome renders the new shell surfaces from the catalog" do
    assigns = catalog_assigns("/settings/audit/events")

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
        legacy_subnav={@legacy_subnav}
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

  test "catalog shell renders the phase-3 surfaces (header, search, status, palette)" do
    assigns = catalog_assigns("/settings/audit/events")

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@active_view}
        active_category={@active_category}
        breadcrumbs={@breadcrumbs}
        nav_tree={@nav_tree}
        palette={@palette}
        stats={@stats}
        legacy_subnav={@legacy_subnav}
      >
        <p data-test="page-body">audit events body</p>
      </Shell.settings_chrome>
      """)

    # Header branding + the Ctrl+K palette trigger.
    assert html =~ "ServiceRadar Console"
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
    assert html =~ "Audit events (24h)"
    assert html =~ "Config changes"
    refute html =~ "Cluster health"

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
    refute html =~ ~s(class="stat py-2")
  end

  test "original chrome renders the legacy nav and no new palette" do
    assigns = %{
      settings_ui: :original,
      current_path: "/settings/audit/history",
      current_scope: auditor_scope(),
      legacy_subnav: :audit
    }

    html =
      rendered_to_string(~H"""
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        legacy_subnav={@legacy_subnav}
      >
        <p data-test="page-body">legacy body</p>
      </Shell.settings_chrome>
      """)

    # Legacy audit sub-nav tabs are present.
    assert html =~ "Events"
    assert html =~ "History"
    # Page body still renders.
    assert html =~ ~s(data-test="page-body")
    # The new catalog-only command palette is absent in the legacy chrome.
    refute html =~ ~s(id="settings-command-palette")
  end

  test "ui_toggle links to the opposite mode with a local return path" do
    assigns = %{current_path: "/settings/audit/events", mode: :catalog}

    html =
      rendered_to_string(~H"""
      <Shell.ui_toggle current_path={@current_path} mode={@mode} />
      """)

    assert html =~ "/settings/ui-preference?"
    assert html =~ "mode=original"
    assert html =~ "Original UI"
  end
end
