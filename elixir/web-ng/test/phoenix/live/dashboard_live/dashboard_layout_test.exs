defmodule ServiceRadarWebNGWeb.DashboardLive.DashboardLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.VirtualizationPanel

  @moduletag :db_free

  test "combines events over time above observability metrics in one side card" do
    html =
      render_component(&ObservabilityPanel.render/1,
        dashboard: %{
          observability_metrics: [],
          security_trend: [],
          security_trend_max: 0,
          time_window_label: "24h"
        }
      )

    events_at = :binary.match(html, "Events Over Time")
    metrics_at = :binary.match(html, "Metrics")

    assert html =~ "Observability"
    assert html =~ "24h"
    assert html =~ "sr-ops-observability-split"
    assert html =~ "sr-ops-observability-panel"
    refute html =~ "sr-ops-span-full"
    refute html =~ "lg:col-span-12"
    assert html =~ "No event trend data"
    refute html =~ "Observability Metrics"
    assert events_at < metrics_at
  end

  test "empty KPI cards start loading independently of NetFlow" do
    empty = Data.empty()
    assets = Enum.find(empty.kpi_cards, &(&1.title == "Total Assets"))

    derived =
      Data.derive(
        Map.merge(empty, %{
          device_summary: %{total: 42, available: 40, unavailable: 2},
          kpi_loading: %{assets: false},
          loaded: %{inventory: true}
        })
      )

    ready = Enum.find(derived.kpi_cards, &(&1.title == "Total Assets"))

    assert assets.loading
    assert empty.module_states.netflow == :loading
    refute ready.loading
    assert ready.value == "42"
    assert derived.module_states.inventory == :active
    assert derived.module_states.netflow == :loading
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
