defmodule ServiceRadarWebNGWeb.DashboardLive.Index.Page do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.AlertsPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.CameraPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.DashboardLive.Index.FieldSurveyPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.MapPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.ObservabilityPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.VirtualizationPanel
  alias ServiceRadarWebNGWeb.DashboardLive.Index.VulnerableAssetsPanel

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
      hide_breadcrumb
    >
      <div
        class="sr-ops-dashboard"
        data-testid="operations-dashboard"
        data-dashboard-modules={Enum.join(@dashboard_modules, " ")}
      >
        <section class="sr-ops-kpi-grid" aria-label="Operational summary">
          <Common.kpi_card
            :for={card <- Common.visible_kpi_cards(@kpi_cards, @camera_summary, @survey_summary)}
            card={card}
          />
        </section>

        <section class="sr-ops-grid-primary">
          <MapPanel.render dashboard={assigns} />
          <ObservabilityPanel.render
            dashboard={assigns}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </section>

        <section class="sr-ops-grid-secondary">
          <FieldSurveyPanel.render dashboard={assigns} />
        </section>

        <section class="sr-ops-grid-trio" aria-label="Asset and threat summary">
          <div class="sr-ops-grid-trio-stack">
            <VulnerableAssetsPanel.render dashboard={assigns} />
            <ThreatPanel.render
              dashboard={assigns}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>
          <VirtualizationPanel.render dashboard={assigns} />
          <CameraPanel.render dashboard={assigns} />
        </section>

        <section class="sr-ops-grid-alerts">
          <AlertsPanel.render
            dashboard={assigns}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
