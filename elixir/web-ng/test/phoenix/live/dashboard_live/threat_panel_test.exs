defmodule ServiceRadarWebNGWeb.DashboardLive.ThreatPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel
  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  @moduletag :db_free

  test "spans the full dashboard row instead of a leftover third-width column" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{threat_intel_summary: summary(%{})}
      )

    assert html =~ "sr-ops-span-full"
    assert html =~ "lg:col-span-12"
    refute html =~ "lg:col-span-4"
  end

  test "lists matched IPs with inventory and NetFlow links" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{
          threat_intel_summary:
            summary(%{
              matched_ips: 1,
              indicator_matches: 3,
              recent_matches: [
                %{
                  ip: "198.51.100.23",
                  match_count: 3,
                  max_severity: 5,
                  sources: ["alienvault_otx"],
                  looked_up_label: "16 Aug 2026 07:53",
                  device_uid: "alma-test01",
                  hostname: "alma-test01"
                }
              ]
            })
        }
      )

    assert html =~ "198.51.100.23"
    assert html =~ "alma-test01"
    assert html =~ "3 hits"
    assert html =~ "16 Aug 2026 07:53"
    assert html =~ ~s(href="/devices/alma-test01")
    assert html =~ "in%3Anetflows+ip%3A%22198.51.100.23%22"
    assert html =~ "Device"
    assert html =~ "Flows"
    refute html =~ "No current NetFlow IOC matches."
  end

  test "unknown matched IPs still have an inventory search and flow drill-down" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{
          threat_intel_summary:
            summary(%{
              matched_ips: 1,
              recent_matches: [
                %{
                  ip: "203.0.113.77",
                  match_count: 1,
                  looked_up_label: "15 Aug 2026 21:10",
                  device_uid: nil,
                  hostname: nil
                }
              ]
            })
        }
      )

    assert html =~ "203.0.113.77"
    assert html =~ "Inventory"
    assert html =~ "in%3Adevices+ip%3A%22203.0.113.77%22"
    assert html =~ "/observability/netflows"
  end

  test "last success includes a calendar date" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{
          threat_intel_summary:
            summary(%{
              latest_success_label: "16 Aug 2026 07:53",
              latest_success_at: ~U[2026-08-16 07:53:00Z]
            })
        }
      )

    assert html =~ "Last success 16 Aug 2026 07:53 UTC"
    assert html =~ "2026-08-16T07:53:00Z"
    refute html =~ "Last success 07:53 UTC"
  end

  test "device and netflow paths encode the matched IP" do
    assert ThreatIntelLinks.device_path("198.51.100.23", "host-1") == "/devices/host-1"
    assert ThreatIntelLinks.device_path("198.51.100.23") =~ "in%3Adevices+ip%3A%22198.51.100.23%22"
    assert ThreatIntelLinks.netflow_path("198.51.100.23") =~ "in%3Anetflows+ip%3A%22198.51.100.23%22"
  end

  defp summary(overrides) do
    Map.merge(
      %{
        imported_indicators: 25_100,
        source_objects: 5_000,
        matched_ips: 0,
        indicator_matches: 0,
        max_severity: 0,
        latest_provider: "alienvault_otx",
        latest_source: "alienvault_otx",
        latest_status: "ok",
        latest_message: "OTX export: 1 pages",
        latest_success_label: "16 Aug 2026 07:53",
        latest_attempt_label: "",
        latest_success_at: ~U[2026-08-16 07:53:00Z],
        latest_attempt_at: nil,
        recent_matches: []
      },
      overrides
    )
  end
end
