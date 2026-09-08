defmodule ServiceRadar.Dashboards do
  @moduledoc """
  Dashboard package, dashboard instance, and authored dashboard management.

  Dashboard packages are browser-side WASM renderers with JSON manifests. They
  are separate from agent-executed plugins and are hosted by web-ng.

  Authored dashboards are saved SRQL dashboards rendered by web-ng-owned
  visualization components.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Dashboards.DashboardPackage
    resource ServiceRadar.Dashboards.DashboardInstance
    resource ServiceRadar.Dashboards.AuthoredDashboard
    resource ServiceRadar.Dashboards.DashboardPanel
    resource ServiceRadar.Dashboards.DashboardReportSchedule
    resource ServiceRadar.Dashboards.DashboardReportDelivery
    resource ServiceRadar.Dashboards.DashboardAccessGrant
    resource ServiceRadar.Dashboards.DashboardInstanceAccessGrant
    resource ServiceRadar.Dashboards.DashboardUserPreference
  end
end
