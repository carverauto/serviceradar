defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Backend do
  @moduledoc """
  Graph write/read target flags (`GRAPH_BACKEND`, `GRAPH_READ`).

  Arbitration, confidence gating, and stale-TTL stay in TopologyGraph; this
  module only says which store the persist/query adapter should talk to.
  """

  require Logger

  @type backend :: :age | :dual | :dgraph
  @type read :: :age | :dgraph

  @unresolved_url_marker {__MODULE__, :dgraph_url_unresolved}

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

  @doc """
  Whether topology writes should reach Dgraph.

  An unresolvable Dgraph endpoint means no write can succeed, so this is false
  and the persist adapter skips rather than failing once per device, interface,
  link and MTR edge on every mapper cycle. Under `dual` that is quiet: AGE still
  captures the write. Under `dgraph` there is no second store, so the dropped
  writes are reported - once per transition, not once per edge.
  """
  @spec write_dgraph?() :: boolean()
  def write_dgraph? do
    case {backend(), ServiceRadar.Dgraph.url()} do
      {:age, _} ->
        false

      {_backend, {:ok, _url}} ->
        note_dgraph_url_resolved()
        true

      {:dual, {:error, _reason}} ->
        false

      {:dgraph, {:error, reason}} ->
        warn_dgraph_url_unresolved(reason)
        false
    end
  end

  defp warn_dgraph_url_unresolved(reason) do
    if :persistent_term.get(@unresolved_url_marker, :none) == :warned do
      :ok
    else
      :persistent_term.put(@unresolved_url_marker, :warned)

      Logger.error(
        "GRAPH_BACKEND=dgraph but the Dgraph URL is unresolved (#{reason}). " <>
          "AGE writes are off in this mode, so topology writes are being dropped " <>
          "entirely. Set DGRAPH_URL, or DGRAPH_HOST with DGRAPH_PORT."
      )

      :ok
    end
  end

  defp note_dgraph_url_resolved do
    if :persistent_term.get(@unresolved_url_marker, :none) == :warned do
      :persistent_term.put(@unresolved_url_marker, :none)

      Logger.info("Dgraph URL resolved; topology writes to Dgraph have resumed")
    end

    :ok
  end

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
