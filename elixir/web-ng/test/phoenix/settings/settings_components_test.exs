defmodule ServiceRadarWebNGWeb.SettingsComponentsTest do
  @moduledoc """
  Verifies the legacy `SettingsComponents.settings_tabs/2` adapter (OpenSpec
  redesign-settings-catalog-nav, task 1.6). The top-level tab bar is unchanged
  in appearance, but every tab now sources its route from the single
  `Settings.Catalog` source of truth. This locks in that the adapter still emits
  the exact canonical routes so the legacy chrome renders identically.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.RBAC.Catalog, as: RBACCatalog
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.SettingsComponents

  @moduletag :db_free

  # A scope holding every permission and a (non-nil) user so all top-level tabs
  # are shown regardless of feature flags (whose checks are all ORed with a held
  # permission at the top level).
  defp superuser_scope do
    %Scope{
      user: %{id: "test-user"},
      permissions: MapSet.new(RBACCatalog.permission_keys())
    }
  end

  defp scope_with_permissions(permissions) do
    %Scope{
      user: %{id: "test-user"},
      permissions: MapSet.new(permissions)
    }
  end

  defp tab_route(tabs, label) do
    case Enum.find(tabs, &(&1.label == label)) do
      nil -> nil
      tab -> tab[:navigate] || tab[:href]
    end
  end

  describe "settings_tabs/2 adapter (catalog-sourced routes)" do
    test "every top-level tab points at its canonical catalog route" do
      tabs = SettingsComponents.settings_tabs("/settings/cluster", superuser_scope())

      # Exact routes the tab bar rendered before task 1.6 re-pointed them at the
      # catalog. These MUST stay byte-identical to keep the legacy chrome stable.
      assert tab_route(tabs, "Cluster") == "/settings/cluster"
      assert tab_route(tabs, "Discovery") == "/settings/networks"
      assert tab_route(tabs, "Network") == "/settings/flows"
      assert tab_route(tabs, "Mail") == "/settings/mail"
      assert tab_route(tabs, "Security") == "/settings/security/vulnerability-feeds"
      assert tab_route(tabs, "Events") == "/settings/rules"
      assert tab_route(tabs, "Dashboards") == "/settings/dashboards/packages"
      assert tab_route(tabs, "Edge Ops") == "/settings/agents/releases"
      assert tab_route(tabs, "Ansible") == "/settings/ansible"
      assert tab_route(tabs, "Jobs") == "/admin/jobs"
      assert tab_route(tabs, "Auth") == "/settings/auth/users"
      assert tab_route(tabs, "Audit") == "/settings/audit/events"
    end

    test "an empty scope shows no tabs (legacy visibility preserved)" do
      assert SettingsComponents.settings_tabs("/settings/cluster", nil) == []
    end

    test "Ansible tab requires access to a retained settings workflow" do
      controller_tabs =
        SettingsComponents.settings_tabs(
          "/settings/cluster",
          scope_with_permissions(["ansible.controllers.manage"])
        )

      repository_tabs =
        SettingsComponents.settings_tabs(
          "/settings/cluster",
          scope_with_permissions(["ansible.repositories.manage"])
        )

      schedule_only_tabs =
        SettingsComponents.settings_tabs(
          "/settings/cluster",
          scope_with_permissions(["ansible.schedules.manage"])
        )

      assert tab_route(controller_tabs, "Ansible") == "/settings/ansible"
      assert tab_route(repository_tabs, "Ansible") == "/settings/ansible"
      assert is_nil(tab_route(schedule_only_tabs, "Ansible"))
    end
  end
end
