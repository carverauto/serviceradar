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
    refute html =~ "lg:col-span-4"
    refute html =~ "sr-ops-span-full"
    refute html =~ "lg:col-span-12"
  end

  test "optional camera and fieldsurvey cards do not pin a half-row span" do
    camera_src = File.read!(index_path("camera_panel.ex"))
    survey_src = File.read!(index_path("fieldsurvey_panel.ex"))

    refute camera_src =~ "col-span"
    refute survey_src =~ "col-span"
    assert camera_src =~ "Camera Operations"
    assert survey_src =~ "FieldSurvey Heatmap"
  end

  test "dashboard CSS grows leftover flex tracks instead of leaving empty columns" do
    css = File.read!(css_path())

    assert css =~ ".sr-ops-grid-secondary > *"
    assert css =~ "flex: 1 1 0%"
    assert css =~ ".sr-ops-grid-secondary:not(:has(> .sr-ops-panel))"
    assert css =~ ".sr-ops-kpi-grid > *"
    assert css =~ ".sr-ops-grid-trio > *"
    assert css =~ "align-items: stretch"
    refute css =~ ~r/\.sr-ops-grid-secondary[^{]*\{[^}]*grid-template-columns:\s*repeat\(12/
    refute css =~ "lg:col-span-6"
  end

  test "dashboard map stays compact and does not grow with observability metrics" do
    css = File.read!(css_path())

    assert css =~ ".sr-ops-grid-primary .sr-ops-map-shell"
    assert css =~ "min-height: 11rem"
    refute css =~ ~r/\.sr-ops-grid-primary \.sr-ops-map-shell[^{]*\{[^}]*min-height:\s*22rem/
    assert css =~ ".sr-ops-observability-split .sr-ops-metric-sparkline-wrap"
    assert css =~ "height: 2.4rem"
  end

  test "dashboard index markup never pins a column span" do
    for path <- Path.wildcard(Path.join(index_dir(), "*.ex")) do
      refute File.read!(path) =~ "col-span",
             "#{Path.basename(path)} pins a column span that leaves empty tracks"
    end
  end

  defp css_path do
    Path.expand("../../../../assets/css/app.css", __DIR__)
  end

  defp index_dir do
    Path.expand("../../../../lib/serviceradar_web_ng_web/live/dashboard_live/index", __DIR__)
  end

  defp index_path(name), do: Path.join(index_dir(), name)
end
