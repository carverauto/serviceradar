defmodule ServiceRadar.Dashboards do
  @moduledoc """
  Dashboard package and dashboard instance management.

  Dashboard packages are browser-side WASM renderers with JSON manifests. They
  are separate from agent-executed plugins and are hosted by web-ng.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.Dashboards.DashboardPackage
    resource ServiceRadar.Dashboards.DashboardInstance
  end
end
