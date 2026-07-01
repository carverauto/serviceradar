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
        views: Catalog.visible_views(scope, category.id)
      },
      palette: Catalog.palette_index(scope),
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
        legacy_subnav={@legacy_subnav}
      >
        <p data-test="page-body">audit events body</p>
      </Shell.settings_chrome>
      """)

    # View list (menu) + breadcrumbs + category switcher come from the catalog.
    assert html =~ "Audit Trail"
    assert html =~ "Audit &amp; System Log"
    assert html =~ "Lockouts"
    # Ctrl+K command palette dialog is present.
    assert html =~ ~s(id="settings-command-palette")
    assert html =~ "CommandPalette"
    # The page body is rendered in the content slot.
    assert html =~ ~s(data-test="page-body")
    # The unpermitted logs-gated view is NOT listed for this scope.
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
        legacy_subnav={@legacy_subnav}
      >
        <p data-test="page-body">audit events body</p>
      </Shell.settings_chrome>
      """)

    # Header branding + the Ctrl+K palette trigger.
    assert html =~ "ServiceRadar Console"
    assert html =~ "data-command-palette-open"
    assert html =~ "Press Ctrl+K to jump anywhere"

    # Topbar "Portal State" indicator.
    assert html =~ "Portal State: Connected"

    # Left panel "Search views…" filter input + its hook.
    assert html =~ "SettingsViewFilter"
    assert html =~ "Search views"

    # Status-card strip is present and degrades to em dashes with empty stats.
    assert html =~ "Cluster health"
    assert html =~ "Connected agents"
    assert html =~ "Pending jobs"
    assert html =~ "Active alerts"

    # Command palette rows surface the per-view description + section header.
    assert html =~ "Settings &amp; Deep Sections"
    assert html =~ "Browse stateless security events and audit entries."

    # The final breadcrumb is a "Navigate Views" sibling jumper.
    assert html =~ "Navigate Views"

    # No leftover second icon rail: the shell must not render `.sr-ops-sidebar`.
    refute html =~ "sr-ops-sidebar"
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
