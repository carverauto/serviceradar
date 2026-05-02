defmodule ServiceRadar.WifiMap do
  @moduledoc """
  Database-backed WiFi-map data collected by customer-owned map plugins.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(ServiceRadar.WifiMap.Source)
    resource(ServiceRadar.WifiMap.Batch)
    resource(ServiceRadar.WifiMap.SiteReference)
    resource(ServiceRadar.WifiMap.Site)
    resource(ServiceRadar.WifiMap.SiteSnapshot)
    resource(ServiceRadar.WifiMap.AccessPointObservation)
    resource(ServiceRadar.WifiMap.ControllerObservation)
    resource(ServiceRadar.WifiMap.RadiusGroupObservation)
    resource(ServiceRadar.WifiMap.FleetHistory)
    resource(ServiceRadar.WifiMap.MapView)
  end
end
