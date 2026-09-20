defmodule ServiceRadar.NetworkConfig do
  @moduledoc """
  Domain for retrieved device configurations and parsed interface facts.

  Revision bodies and parsed facts live in CNPG. The topology projector
  turns facts into Prefix / Interface updates on the configured graph
  backend; it does not treat parser output as the graph.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource ServiceRadar.NetworkConfig.Revision
    resource ServiceRadar.NetworkConfig.InterfaceFact
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
