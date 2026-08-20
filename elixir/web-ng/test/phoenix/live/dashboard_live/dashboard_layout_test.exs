defmodule ServiceRadarWebNGWeb.DashboardLive.DashboardLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.VirtualizationPanel

  @moduletag :db_free

  test "combines metrics and events in one full-width observability card" do
    html =
      render_component(&ObservabilityPanel.render/1,
        dashboard: %{
          observability_metrics: [],
          security_trend: [],
          security_trend_max: 0,
          time_window_label: "24h"
        }
      )

    assert html =~ "Observability"
    assert html =~ "Metrics"
    assert html =~ "Events Over Time"
    assert html =~ "24h"
    assert html =~ "sr-ops-observability-split"
    assert html =~ "sr-ops-span-full"
    assert html =~ "lg:col-span-12"
    assert html =~ "No event trend data"
    refute html =~ "Observability Metrics"
  end

  test "keeps virtualization on the three-card row when inventory is empty" do
    html =
      render_component(&VirtualizationPanel.render/1,
        dashboard: %{
          virtualization_summary: %{
            available: false,
            status_label: "No inventory",
            status_tone: "idle"
          }
        }
      )

    assert html =~ "Virtualization Efficiency"
    assert html =~ "No hypervisor inventory"
    assert html =~ "lg:col-span-4"
    refute html =~ "sr-ops-span-full"
    refute html =~ "lg:col-span-12"
  end
end
