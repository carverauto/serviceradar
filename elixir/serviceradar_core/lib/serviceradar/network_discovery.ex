defmodule ServiceRadar.NetworkDiscovery do
  @moduledoc """
  Domain for mapper-based network discovery jobs.

  NetworkDiscovery manages discovery jobs, seed inputs, and credentials that are
  compiled into mapper configs and delivered to agents via GetConfig.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.NetworkDiscovery.MapperJob
    resource ServiceRadar.NetworkDiscovery.MapperSeed
    resource ServiceRadar.NetworkDiscovery.MapperMikrotikController
    resource ServiceRadar.NetworkDiscovery.MapperUnifiController
    resource ServiceRadar.NetworkDiscovery.TopologyLink
    resource ServiceRadar.NetworkDiscovery.WorldHead
    resource ServiceRadar.NetworkDiscovery.WorldLayout
    resource ServiceRadar.NetworkDiscovery.WorldPosition
    resource ServiceRadar.NetworkDiscovery.WorldRelation
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
