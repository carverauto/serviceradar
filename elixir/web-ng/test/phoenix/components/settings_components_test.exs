defmodule ServiceRadarWebNGWeb.SettingsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.SettingsComponents

  test "credential manager sees credential rules in the network settings subnav" do
    scope = %Scope{permissions: MapSet.new(["settings.credentials.manage"])}

    top_tabs = SettingsComponents.settings_tabs("/settings/networks/credentials", scope)

    html =
      render_component(&SettingsComponents.network_nav/1,
        current_path: "/settings/networks/credentials",
        current_scope: scope
      )

    assert Enum.any?(top_tabs, &(&1.label == "Discovery" and &1.active))
    assert html =~ "Credential Rules"
    refute html =~ "Sweep Profiles"
  end
end
