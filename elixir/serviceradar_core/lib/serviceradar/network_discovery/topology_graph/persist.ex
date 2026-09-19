defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Persist do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Backend

  @spec execute_age(String.t(), keyword()) :: :ok | {:error, term()}
  def execute_age(cypher, opts \\ []) when is_binary(cypher) do
    if Backend.write_age?() do
      Graph.execute(cypher, opts)
    else
      :ok
    end
  end
end
