defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceSummarySnmpPollingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents
  alias ServiceRadarWebNGWeb.DeviceLive.SNMPPollingSource

  @moduletag :db_free

  test "SNMP card names the polling profile and credential" do
    html =
      render_component(&DeviceSummaryComponents.device_summary_section/1,
        device_row: %{
          "hostname" => "U6-Mesh",
          "ip" => "192.168.1.16",
          "metadata" => %{"snmp_name" => "U6-Mesh", "sys_contact" => "root@localhost"}
        },
        snmp_polling_source: %{
          source: :profile,
          source_label: "SNMP profile",
          profile_id: "11111111-1111-1111-1111-111111111111",
          profile_name: "UniFi Access Points",
          profile_href: "/settings/snmp/11111111-1111-1111-1111-111111111111/edit",
          profile_enabled: true,
          profile_is_default: false,
          target_query: "in:devices type:\"Access Point\"",
          poll_interval: 60,
          version: "V2C",
          credential_label: "unifi-ro (internal)",
          credential_configured?: true,
          settings_href: "/settings/snmp"
        }
      )

    assert html =~ "data-testid=\"snmp-polling-source\""
    assert html =~ "Polling"
    assert html =~ "UniFi Access Points"
    assert html =~ "unifi-ro (internal)"
    assert html =~ "in:devices type:&quot;Access Point&quot;"
    assert html =~ "60s"
    assert html =~ "V2C"
    assert html =~ "/settings/snmp/11111111-1111-1111-1111-111111111111/edit"
    assert html =~ "Manage SNMP profiles"
    refute html =~ "No community or secret"
  end

  test "SNMP card warns when a profile is selected without a credential" do
    html =
      render_component(&DeviceSummaryComponents.device_summary_section/1,
        device_row: %{"hostname" => "U6-Mesh"},
        snmp_polling_source: %{
          SNMPPollingSource.empty()
          | source: :default_profile,
            source_label: "Default profile",
            profile_name: "Public",
            profile_href: "/settings/snmp/22222222-2222-2222-2222-222222222222/edit",
            credential_configured?: false,
            credential_label: "None"
        }
      )

    assert html =~ "Default profile"
    assert html =~ "Public"
    assert html =~ "No community or secret is attached"
  end
end
