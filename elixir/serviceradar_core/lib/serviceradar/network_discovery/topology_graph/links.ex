defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Links do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  @spec upsert_links([map()]) :: :ok | {:error, term()}
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    links = Enum.sort_by(links, &link_observed_unix/1)

    {diagnostics, dgraph_links} =
      Enum.reduce(
        links,
        {Projection.empty_projection_diagnostics(), []},
        &reduce_topology_link/2
      )

    # Dgraph receives every projected link in one batch, in observation order.
    with :ok <- DgraphPersist.upsert_links(Enum.reverse(dgraph_links)) do
      Logger.info("Topology projection diagnostics: #{inspect(diagnostics)}")

      :ok
    end
  end

  @doc """
  The graph-wide passes that follow link projection: global stale-evidence
  pruning and the canonical rebuild. They read and rewrite the whole graph, so
  they run once per burst of device projections rather than once per device.
  """
  @spec run_global_passes() :: :ok | {:error, term()}
  def run_global_passes do
    Pruning.maybe_prune_stale_mapper_evidence_links()

    case CanonicalRebuild.rebuild_canonical_device_links() do
      {:error, reason, _stats} ->
        Logger.warning(
          "Canonical topology rebuild failed: #{CanonicalRebuild.failure_text(reason)}"
        )

        {:error, reason}

      _ ->
        :ok
    end
  end

  defp link_observed_unix(link) when is_map(link) do
    case Map.get(link, :timestamp) || Map.get(link, "timestamp") do
      %DateTime{} = timestamp ->
        DateTime.to_unix(timestamp, :microsecond)

      %NaiveDateTime{} = timestamp ->
        NaiveDateTime.diff(timestamp, ~N[1970-01-01 00:00:00], :microsecond)

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} ->
            DateTime.to_unix(parsed, :microsecond)

          _ ->
            case NaiveDateTime.from_iso8601(timestamp) do
              {:ok, parsed} -> NaiveDateTime.diff(parsed, ~N[1970-01-01 00:00:00], :microsecond)
              _ -> 0
            end
        end

      _ ->
        0
    end
  end

  defp reduce_topology_link(link, {diagnostics, dgraph_links}) do
    case Projection.projection_payload(link) do
      nil ->
        reason = Projection.drop_reason(link) || :missing_ids
        emit_neighbor_dropped(link, reason)
        Logger.debug("Skipping topology link missing device identifiers")
        {Projection.increment_diagnostic(diagnostics, :rejected, reason), dgraph_links}

      payload ->
        case Projection.projection_mode(payload) do
          {:backbone, reason} ->
            {Projection.increment_diagnostic(diagnostics, :accepted, reason),
             [{payload, "CONNECTS_TO"} | dgraph_links]}

          {:auxiliary, reason} ->
            {Projection.increment_diagnostic(diagnostics, :accepted, reason),
             [{payload, Projection.evidence_relation_type(payload)} | dgraph_links]}

          {:skip, reason} ->
            {Projection.increment_diagnostic(diagnostics, :rejected, reason), dgraph_links}
        end
    end
  end

  # Accounting for links dropped because their neighbor never resolved to (or
  # was never promoted to) a canonical `sr:` identity. These links are pure
  # evidence (they stay persisted in mapper_topology_links) but MUST NOT write
  # non-`sr:` pseudo-vertices into the topology graph. Public for tests.
  @doc false
  def emit_neighbor_dropped(link, reason)
      when reason in [:neighbor_unresolved, :neighbor_not_canonical] do
    :telemetry.execute(
      [:serviceradar, :mapper_topology, :neighbor_dropped],
      %{count: 1},
      %{reason: reason, protocol: Utils.non_blank(Utils.link_value(link, :protocol)) || "unknown"}
    )
  end

  def emit_neighbor_dropped(_link, _reason), do: :ok
end
