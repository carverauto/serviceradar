defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.DgraphRebuild do
  @moduledoc false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.Conflicts
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @evidence_kinds ~w(CONNECTS_TO LOGICAL_PEER HOSTED_ON INFERRED_TO ATTACHED_TO OBSERVED_TO)
  @canonical_kinds ~w(CONNECTS_TO LOGICAL_PEER HOSTED_ON)
  @relation_rank %{
    "CONNECTS_TO" => 5,
    "LOGICAL_PEER" => 4,
    "HOSTED_ON" => 4,
    "INFERRED_TO" => 3,
    "ATTACHED_TO" => 2,
    "OBSERVED_TO" => 1
  }
  @confidence_rank %{"high" => 3, "medium" => 2, "low" => 1}
  @fields ~w(protocol evidence_class ingestor confidence_tier if_name_ab if_name_ba
             if_index_ab if_index_ba flow_pps_ab flow_pps_ba flow_bps_ab flow_bps_ba
             capacity_bps telemetry_eligible last_seen mutation_id agent_id
             pair_support_rank)a
  @directional_fields ~w(if_name if_index flow_pps flow_bps)a

  # Both sets come from one Dgraph read. Evidence has already passed Projection's
  # confidence/interface policy at ingest; it must not be reconstructed from AGE.
  def read_inputs do
    fields = Enum.map_join(@fields, "\n", &"#{&1}: topo.#{&1}")

    query = """
    {
      edges(func: type(TopologyEdge)) @filter(NOT eq(topo.stale, true) AND
        (eq(topo.kind, "CANONICAL_TOPOLOGY") OR
         (eq(topo.ingestor, "mapper_topology_v1") AND
          eq(topo.kind, #{Jason.encode!(@evidence_kinds)})))) {
        relation: topo.kind
        #{fields}
        source: topo.src { id: device.id interfaces: device.interfaces {
          key: iface.key name: iface.name index: iface.if_index
        } }
        target: topo.dst { id: device.id interfaces: device.interfaces {
          key: iface.key name: iface.name index: iface.if_index
        } }
      }
    }
    """

    case Dgraph.query(query) do
      {:ok, %{"edges" => rows}} when is_list(rows) -> decode_inputs(rows)
      {:error, _} = error -> error
      _ -> {:error, :invalid_dgraph_rebuild_response}
    end
  end

  def decode_inputs(rows) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, %{evidence: [], canonical: []}}, fn row, {:ok, inputs} ->
      case decode_edge(row) do
        {:ok, edge} ->
          bucket = if edge.relation == "CANONICAL_TOPOLOGY", do: :canonical, else: :evidence
          {:cont, {:ok, Map.update!(inputs, bucket, &[edge | &1])}}

        {:error, _} = error ->
          if row["relation"] == "CANONICAL_TOPOLOGY" do
            # Never turn an incomplete canonical read into a destructive empty rebuild.
            {:halt, error}
          else
            # The AGE selector excludes unresolved/self endpoints and undated evidence.
            {:cont, {:ok, inputs}}
          end
      end
    end)
  end

  def fingerprint(%{evidence: evidence}) do
    evidence
    |> Enum.map(fn edge ->
      edge
      |> Map.take([
        :source,
        :target,
        :relation,
        :protocol,
        :evidence_class,
        :confidence_tier,
        :if_name_ab,
        :if_name_ba,
        :if_index_ab,
        :if_index_ba,
        :last_seen
      ])
      |> Map.update!(:last_seen, &String.slice(&1, 0, 13))
      |> Enum.sort()
    end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&"dgraph:#{&1}")
  end

  def rebuild(stale_cutoff) do
    with {:ok, inputs} <- read_inputs() do
      {edges, stats} =
        plan(inputs, stale_cutoff,
          min_upsert_floor: CanonicalRebuild.canonical_rebuild_min_upsert_floor(),
          max_prune_fraction: CanonicalRebuild.canonical_prune_max_fraction(),
          prune_override: CanonicalRebuild.canonical_prune_guard_override?()
        )

      with :ok <- Dgraph.rebuild_canonical(edges) do
        report_guards(stats)
        min_edges = CanonicalRebuild.canonical_rebuild_min_edges()

        self_heal_result =
          if CanonicalRebuild.self_heal_needed?(
               stats.after_prune_edges,
               stats.mapper_evidence_edges,
               min_edges
             ) do
            CanonicalRebuild.finalize_self_heal_outcome(
              stats.before_edges,
              stats.after_prune_edges,
              stats.mapper_evidence_edges,
              min_edges
            )
          else
            %{status: :skipped}
          end

        {:ok,
         stats
         |> Map.put(:input_fingerprint, fingerprint(inputs))
         |> Map.put(:self_heal_result, self_heal_result)}
      end
    end
  end

  # Reconcile the full set before calling the existing typed replacement API.
  # Retained edges keep their original discovery time and telemetry; rebuilding
  # a view is not a new observation of a link.
  def plan(%{evidence: evidence, canonical: existing}, stale_cutoff, opts \\ []) do
    fresh =
      Enum.filter(evidence, &(&1.last_seen >= stale_cutoff and &1.relation != "OBSERVED_TO"))

    selected =
      fresh |> Enum.group_by(&identity/1) |> Enum.map(fn {_key, group} -> select(group) end)

    current = Map.new(existing, &{identity(&1), &1})

    replacements =
      Map.new(selected, fn edge ->
        previous = Map.get(current, identity(edge), %{})
        {identity(edge), Map.merge(previous, Map.drop(edge, telemetry_fields()))}
      end)

    eligible = Map.filter(replacements, fn {_key, edge} -> edge.relation in @canonical_kinds end)
    merged = Map.merge(current, eligible)

    demotions =
      merged
      |> Map.values()
      |> Enum.filter(&physical?/1)
      |> Enum.map(&conflict_row/1)
      |> Conflicts.competing_edge_demotions()
      |> MapSet.new()

    max_seen = evidence |> Enum.map(& &1.last_seen) |> Enum.max(fn -> nil end)
    floor = Keyword.get(opts, :min_upsert_floor, 0)

    starved =
      CanonicalRebuild.starvation_check(
        map_size(merged),
        length(evidence),
        max_seen,
        stale_cutoff,
        floor
      ) == :starved

    stale_keys =
      for {key, edge} <- merged,
          edge.ingestor == "mapper_topology_v1" and edge.last_seen < stale_cutoff,
          do: key

    guard =
      CanonicalRebuild.prune_guard_check(
        length(stale_keys),
        length(existing),
        Keyword.get(opts, :max_prune_fraction, 0.5),
        Keyword.get(opts, :prune_override, false)
      )

    prune_result =
      cond do
        starved -> :skipped_starved
        guard == :allow -> :ok
        true -> {:refused, elem(guard, 1)}
      end

    # A fresh, explicitly reclassified relation leaves canonical adjacency even
    # before TTL, matching the AGE canonical predicate used by dual-write.
    rejected_keys =
      for {key, edge} <- replacements, edge.relation not in @canonical_kinds, do: key

    demoted_keys =
      for {key, edge} <- merged, MapSet.member?(demotions, {edge.source, edge.target}), do: key

    pruned = if prune_result == :ok, do: Map.drop(merged, stale_keys), else: merged
    final = Map.drop(pruned, rejected_keys ++ demoted_keys)

    edges =
      Enum.map(final, fn {_key, edge} ->
        edge |> Map.delete(:relation) |> Map.put(:kind, :canonical_topology)
      end)

    {edges,
     %{
       before_edges: length(existing),
       mapper_evidence_edges: length(evidence),
       after_upsert_edges: map_size(merged),
       after_prune_edges: length(edges),
       same_port_demotions: {:ok, MapSet.size(demotions)},
       stale_cutoff: stale_cutoff,
       evidence_max_last_observed_at: max_seen,
       starved: starved,
       prune_result: prune_result,
       prune_candidates: length(stale_keys),
       min_upsert_floor: floor,
       max_prune_fraction: Keyword.get(opts, :max_prune_fraction, 0.5),
       self_heal_result: %{status: :skipped},
       lock_skipped: false
     }}
  end

  defp decode_edge(
         %{
           "source" => [%{"id" => "sr:" <> _ = source} = src],
           "target" => [%{"id" => "sr:" <> _ = target} = dst],
           "relation" => relation,
           "last_seen" => timestamp
         } = row
       )
       when source != target and is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, observed, _} ->
        edge = Map.new(@fields, &{&1, Map.get(row, Atom.to_string(&1))})

        edge =
          edge
          |> Map.merge(%{
            source: source,
            target: target,
            relation: relation,
            last_seen: observed |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          })
          |> Map.update!(:pair_support_rank, &(&1 || 0))

        edge = edge |> attribute_interface(:ab, src) |> attribute_interface(:ba, dst)
        {:ok, normalize_direction(edge)}

      _ ->
        {:error, :invalid_dgraph_edge_timestamp}
    end
  end

  defp decode_edge(_), do: {:error, :invalid_dgraph_edge_identity}

  defp attribute_interface(edge, direction, endpoint) do
    {name_key, index_key} =
      if direction == :ab, do: {:if_name_ab, :if_index_ab}, else: {:if_name_ba, :if_index_ba}

    interface_key = Utils.interface_id(endpoint["id"], edge[name_key], edge[index_key])
    iface = Enum.find(Map.get(endpoint, "interfaces", []), &(&1["key"] == interface_key)) || %{}
    index = Enum.find([iface["index"], edge[index_key]], 0, &(is_integer(&1) and &1 > 0))
    name = Utils.non_blank(iface["name"] || edge[name_key]) || ""

    # The typed Dgraph link key contains interface names. Use the existing
    # interface-id fallback for index-only ports so parallel links remain distinct.
    name = if name == "" and index > 0, do: "ifindex:#{index}", else: name
    edge |> Map.put(index_key, index) |> Map.put(name_key, name)
  end

  defp normalize_direction(%{source: source, target: target} = edge) when source <= target,
    do: edge

  defp normalize_direction(edge) do
    Enum.reduce(@directional_fields, %{edge | source: edge.target, target: edge.source}, fn field,
                                                                                            acc ->
      {ab, ba} = directional_keys(field)
      acc |> Map.put(ab, edge[ba]) |> Map.put(ba, edge[ab])
    end)
  end

  defp directional_keys(:if_name), do: {:if_name_ab, :if_name_ba}
  defp directional_keys(:if_index), do: {:if_index_ab, :if_index_ba}
  defp directional_keys(:flow_pps), do: {:flow_pps_ab, :flow_pps_ba}
  defp directional_keys(:flow_bps), do: {:flow_bps_ab, :flow_bps_ba}

  defp identity(edge) do
    {edge.source, edge.target, Utils.interface_id(edge.source, edge.if_name_ab, edge.if_index_ab),
     Utils.interface_id(edge.target, edge.if_name_ba, edge.if_index_ba)}
  end

  defp select(group) do
    best =
      Enum.max_by(
        group,
        &{Map.get(@relation_rank, &1.relation, 0),
         Map.get(@confidence_rank, &1.confidence_tier, 0), &1.last_seen, &1.protocol}
      )

    support =
      if Enum.any?(group, &(&1.relation in ~w(LOGICAL_PEER HOSTED_ON INFERRED_TO ATTACHED_TO))),
        do: 1,
        else: 0

    Enum.reduce(
      [:if_index_ab, :if_index_ba],
      Map.put(best, :pair_support_rank, support),
      fn field, edge ->
        Map.put(edge, field, Enum.max_by(group, & &1[field])[field])
      end
    )
  end

  defp physical?(edge),
    do:
      edge.relation in ["CONNECTS_TO", "CANONICAL_TOPOLOGY"] and
        edge.evidence_class == "direct-physical" and
        edge.ingestor == "mapper_topology_v1"

  defp conflict_row(edge),
    do: %{
      "src_id" => edge.source,
      "dst_id" => edge.target,
      "local_if_index_ab" => edge.if_index_ab,
      "local_if_index_ba" => edge.if_index_ba,
      "local_if_name_ab" => edge.if_name_ab,
      "local_if_name_ba" => edge.if_name_ba,
      "pair_support_rank" => Map.get(edge, :pair_support_rank, 0)
    }

  defp telemetry_fields,
    do: [
      :flow_pps_ab,
      :flow_pps_ba,
      :flow_bps_ab,
      :flow_bps_ba,
      :capacity_bps,
      :telemetry_eligible
    ]

  defp report_guards(%{starved: true} = stats) do
    CanonicalRebuild.report_starvation(
      stats,
      stats.stale_cutoff,
      stats.evidence_max_last_observed_at,
      stats.min_upsert_floor
    )
  end

  defp report_guards(stats) do
    HealthConditions.report_recovery(
      CanonicalRebuild.starvation_condition(),
      "Canonical topology rebuild starvation cleared; fresh mapper evidence is flowing again"
    )

    case stats.prune_result do
      {:refused, reason} ->
        CanonicalRebuild.report_prune_refusal(
          reason,
          stats.prune_candidates,
          stats,
          stats.stale_cutoff,
          stats.max_prune_fraction
        )

      _ ->
        :ok
    end
  end
end
