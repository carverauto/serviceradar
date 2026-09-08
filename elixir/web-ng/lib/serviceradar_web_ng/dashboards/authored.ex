defmodule ServiceRadarWebNG.Dashboards.Authored do
  @moduledoc """
  Context for user-authored SRQL dashboards.
  """

  use ServiceRadarWebNG.Dashboards.Authored.Listing
  use ServiceRadarWebNG.Dashboards.Authored.DashboardCrud
  use ServiceRadarWebNG.Dashboards.Authored.PanelsReports
  use ServiceRadarWebNG.Dashboards.Authored.Validation
  use ServiceRadarWebNG.Dashboards.Authored.Sharing
  use ServiceRadarWebNG.Dashboards.Authored.Preview
  use ServiceRadarWebNG.Dashboards.Authored.AshHelpers
  use ServiceRadarWebNG.Dashboards.Authored.Attrs
  use ServiceRadarWebNG.Dashboards.Authored.Normalization
end
