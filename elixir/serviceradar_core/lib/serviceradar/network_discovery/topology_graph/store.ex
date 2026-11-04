defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Store do
  @moduledoc """
  Availability of the topology graph store. Dgraph is the only topology graph;
  there is no alternative backend and no fallback.

  Arbitration, confidence gating, and stale-TTL stay in TopologyGraph; this
  module only says whether a write can reach Dgraph at all.
  """

  require Logger

  @unresolved_url_marker {__MODULE__, :dgraph_url_unresolved}

  @doc """
  Whether topology writes can reach Dgraph.

  An unresolvable Dgraph endpoint means no write can succeed, so this is false
  and the persist adapter skips rather than failing once per device, interface,
  link and MTR edge on every mapper cycle. The dropped writes are reported at
  error level once per transition, not once per edge.
  """
  @spec writable?() :: boolean()
  def writable? do
    case ServiceRadar.Dgraph.url() do
      {:ok, _url} ->
        note_dgraph_url_resolved()
        true

      {:error, reason} ->
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
        "The Dgraph topology graph is not configured (#{reason}), so topology writes " <>
          "are being dropped. Set DGRAPH_URL, or DGRAPH_HOST with DGRAPH_PORT."
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
end
