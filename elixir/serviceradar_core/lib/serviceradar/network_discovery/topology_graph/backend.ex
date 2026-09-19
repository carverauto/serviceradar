defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Backend do
  @moduledoc """
  Graph write/read target flags (`GRAPH_BACKEND`, `GRAPH_READ`).

  Arbitration, confidence gating, and stale-TTL stay in TopologyGraph; this
  module only says which store the persist/query adapter should talk to.
  """

  @type backend :: :age | :dual | :dgraph
  @type read :: :age | :dgraph

  @doc """
  Write target. `age` and `dual` keep AGE Cypher; `dual` and `dgraph` also
  persist through `ServiceRadar.Dgraph`.
  """
  @spec backend() :: backend()
  def backend do
    parse_backend(
      System.get_env("GRAPH_BACKEND") ||
        Application.get_env(:serviceradar_core, :graph_backend, :age)
    )
  end

  @doc """
  Read target for God View, SRQL, and the causal hydrator.
  """
  @spec read() :: read()
  def read do
    parse_read(
      System.get_env("GRAPH_READ") ||
        Application.get_env(:serviceradar_core, :graph_read, :age)
    )
  end

  @spec write_age?() :: boolean()
  def write_age?, do: backend() in [:age, :dual]

  @spec write_dgraph?() :: boolean()
  def write_dgraph?, do: backend() in [:dual, :dgraph]

  @spec read_age?() :: boolean()
  def read_age?, do: read() == :age

  @spec read_dgraph?() :: boolean()
  def read_dgraph?, do: read() == :dgraph

  defp parse_backend(value) when value in [:age, :dual, :dgraph], do: value

  defp parse_backend(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "age" -> :age
      "dual" -> :dual
      "dgraph" -> :dgraph
      _ -> :age
    end
  end

  defp parse_backend(_), do: :age

  defp parse_read(value) when value in [:age, :dgraph], do: value

  defp parse_read(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "dgraph" -> :dgraph
      _ -> :age
    end
  end

  defp parse_read(_), do: :age
end
