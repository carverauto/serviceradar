defmodule ServiceRadarWebNGWeb.DashboardLive.Data do
  @moduledoc false

  use ServiceRadarWebNGWeb.DashboardLive.Data.Load
  use ServiceRadarWebNGWeb.DashboardLive.Data.BasicSummaries
  use ServiceRadarWebNGWeb.DashboardLive.Data.Virtualization
  use ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSummary
  use ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic
  use ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSql
  use ServiceRadarWebNGWeb.DashboardLive.Data.Topology
  use ServiceRadarWebNGWeb.DashboardLive.Data.Mtr
  use ServiceRadarWebNGWeb.DashboardLive.Data.Camera
  use ServiceRadarWebNGWeb.DashboardLive.Data.SurveySummary
  use ServiceRadarWebNGWeb.DashboardLive.Data.SurveyRaster
  use ServiceRadarWebNGWeb.DashboardLive.Data.SurveyGeometry
  use ServiceRadarWebNGWeb.DashboardLive.Data.SurveyMarkers
  use ServiceRadarWebNGWeb.DashboardLive.Data.SecurityTrend
  use ServiceRadarWebNGWeb.DashboardLive.Data.TrafficSparklines
  use ServiceRadarWebNGWeb.DashboardLive.Data.ServiceSparklines
  use ServiceRadarWebNGWeb.DashboardLive.Data.AlertsThreats
  use ServiceRadarWebNGWeb.DashboardLive.Data.StatesCards
  use ServiceRadarWebNGWeb.DashboardLive.Data.EmptyDefaults
  use ServiceRadarWebNGWeb.DashboardLive.Data.DbTimeHelpers
  use ServiceRadarWebNGWeb.DashboardLive.Data.MapHelpers
  use ServiceRadarWebNGWeb.DashboardLive.Data.FormatHelpers

  defp default_srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
