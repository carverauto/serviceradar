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
    resource ServiceRadar.NetworkDiscovery.MapperSNMPCredential
    resource ServiceRadar.NetworkDiscovery.MapperUnifiController
    resource ServiceRadar.NetworkDiscovery.TopologyLink
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
