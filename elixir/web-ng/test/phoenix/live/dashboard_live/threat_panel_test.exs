defmodule ServiceRadarWebNGWeb.DashboardLive.ThreatPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel
  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  @moduletag :db_free

  test "sits on the three-card row instead of a leftover full-width strip" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{threat_intel_summary: summary(%{})}
      )

    refute html =~ "lg:col-span-4"
    refute html =~ "sr-ops-span-full"
    refute html =~ "lg:col-span-12"
  end

  test "keeps feed status, one-line stats, and matches in a compact strip" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{
          threat_intel_summary:
            summary(%{
              imported_indicators: 0,
              latest_provider: nil,
              latest_source: nil,
              latest_status: "idle",
              latest_message: "",
              latest_success_label: "",
              latest_success_at: nil
            })
        }
      )

    assert html =~ "sr-ops-threat-toolbar"
    assert html =~ "sr-ops-threat-stat-grid"
    assert html =~ "Max sev"
    assert html =~ "No current NetFlow IOC matches."
    assert html =~ "Assign the OTX plugin and sync to populate threat context."
    refute html =~ "sr-ops-threat-detail"
    refute html =~ "Max severity"
  end

  test "lists at most three recent matches and reports the overflow" do
    html =
      render_component(&ThreatPanel.render/1,
        dashboard: %{
          threat_intel_summary:
            summary(%{
              matched_ips: 4,
              recent_matches:
                Enum.map(1..4, fn n ->
                  %{
                    ip: "198.51.100.#{n}",
                    match_count: n,
                    looked_up_at: ~U[2026-08-16 07:53:00Z],
                    device_uid: nil,
                    hostname: nil
                  }
                end)
            })
        }
      )

    assert html =~ "198.51.100.1"
    assert html =~ "198.51.100.3"
    refute html =~ "198.51.100.4"
    assert html =~ "+1 more matched IPs"
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
                  looked_up_at: ~U[2026-08-16 07:53:00Z],
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
    assert html =~ "2026-08-16T07:53:00Z"
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
                  looked_up_at: ~U[2026-08-15 21:10:00Z],
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
        timezone: "America/Chicago",
        dashboard: %{
          threat_intel_summary:
            summary(%{
              latest_success_label: "16 Aug 2026 07:53",
              latest_success_at: ~U[2026-08-16 07:53:00Z]
            })
        }
      )

    assert html =~ "Last success"
    assert html =~ "2026-08-16T07:53:00Z"
    assert html =~ ~s(data-user-time-zone="America/Chicago")
  end

  test "device and netflow paths encode the matched IP" do
    assert ThreatIntelLinks.device_path("198.51.100.23", "host-1") == "/devices/host-1"
    assert ThreatIntelLinks.device_path("198.51.100.23") =~ "in%3Adevices+ip%3A%22198.51.100.23%22"
    assert ThreatIntelLinks.netflow_path("198.51.100.23") =~ "in%3Anetflows+ip%3A%22198.51.100.23%22"
  end

  test "investigation path keeps boolean query params" do
    assert ThreatIntelLinks.investigation_path(stale: true) == "/security/threat-intel?stale=true"
    assert ThreatIntelLinks.investigation_path(stale: false) == "/security/threat-intel?stale=false"
    assert ThreatIntelLinks.investigation_path(ip: "198.51.100.23", stale: true) =~ "stale=true"
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
