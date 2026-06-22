defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  @canonical_rebuild_lock_key 1_104_202_506
  @default_canonical_rebuild_timeout_ms 60_000

  def rebuild_canonical_links_from_current do
    _ = rebuild_canonical_links_from_current_with_stats()
    :ok
  end

  def rebuild_canonical_links_from_current_with_stats do
    rebuild_canonical_device_links()
  end

  def rebuild_canonical_device_links do
    case with_canonical_rebuild_lock(&do_rebuild_canonical_device_links/0) do
      {:ok, {:ok, stats}} ->
        {:ok, stats}

      {:ok, {:error, reason, stats}} ->
        {:error, reason, stats}

      {:ok, {:busy, stats}} ->
        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.debug("Canonical topology rebuild skipped; advisory lock busy")
        {:ok, stats}

      {:error, reason} ->
        failure_stats = lock_skipped_rebuild_stats()
        Logger.warning("Canonical topology rebuild lock acquisition failed: #{inspect(reason)}")
        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  @doc false
  @spec canonical_rebuild_timeout_ms() :: pos_integer()
  def canonical_rebuild_timeout_ms do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:canonical_rebuild_timeout_ms, @default_canonical_rebuild_timeout_ms)
    |> Utils.normalize_positive_int(@default_canonical_rebuild_timeout_ms)
  end

  @doc false
  @spec canonical_rebuild_min_edges() :: pos_integer()
  def canonical_rebuild_min_edges do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(:min_canonical_edges, 1)
    |> Utils.normalize_positive_int(1)
  end

  @doc false
  @spec self_heal_needed?(integer(), integer(), integer()) :: boolean()
  def self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges)
      when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
             is_integer(min_canonical_edges) do
    after_prune_edges < min_canonical_edges and mapper_evidence_edges >= min_canonical_edges
  end

  def self_heal_needed?(_after_prune_edges, _mapper_evidence_edges, _min_canonical_edges),
    do: false

  @doc false
  @spec emit_canonical_rebuild_telemetry(:completed | :failed, map(), term() | nil) :: :ok
  def emit_canonical_rebuild_telemetry(status, stats, reason \\ nil)
      when status in [:completed, :failed] and is_map(stats) do
    measurements = %{
      before_edges: Map.get(stats, :before_edges, 0),
      mapper_evidence_edges: Map.get(stats, :mapper_evidence_edges, 0),
      after_upsert_edges: Map.get(stats, :after_upsert_edges, 0),
      after_prune_edges: Map.get(stats, :after_prune_edges, 0)
    }

    metadata =
      maybe_put_reason(
        %{
          status: status,
          stale_cutoff: Map.get(stats, :stale_cutoff),
          prune_result: Map.get(stats, :prune_result),
          telemetry_refresh: Map.get(stats, :telemetry_refresh)
        },
        reason
      )

    :telemetry.execute(
      [:serviceradar, :topology, :canonical_rebuild, status],
      measurements,
      metadata
    )

    :ok
  end

  def canonical_edge_count do
    edge_count_from_query(Queries.canonical_edge_count_query())
  end

  def mapper_evidence_edge_count do
    edge_count_from_query(Queries.mapper_evidence_edge_count_query())
  end

  defp with_canonical_rebuild_lock(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [@canonical_rebuild_lock_key]) do
          {:ok, %{rows: [[true]]}} ->
            fun.()

          {:ok, %{rows: [[false]]}} ->
            {:busy, lock_skipped_rebuild_stats()}

          {:ok, _unexpected} ->
            Repo.rollback(:unexpected_lock_response)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      timeout: canonical_rebuild_timeout_ms()
    )
  end

  defp do_rebuild_canonical_device_links do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()
    stale_cutoff = Utils.stale_cutoff_iso8601()
    min_canonical_edges = canonical_rebuild_min_edges()
    upsert_cypher = Queries.canonical_rebuild_upsert_query(stale_cutoff)

    case Graph.execute(upsert_cypher) do
      :ok ->
        demotion_result = reconcile_competing_same_port_canonical_edges()
        after_upsert_edges = canonical_edge_count()
        prune_result = prune_stale_canonical_device_links(stale_cutoff)
        after_prune_edges = canonical_edge_count()
        telemetry_result = Telemetry.refresh_canonical_edge_telemetry(stale_cutoff)

        {after_prune_edges, self_heal_result} =
          maybe_self_heal_zero_canonical(
            after_prune_edges,
            mapper_evidence_edges,
            stale_cutoff,
            min_canonical_edges
          )

        runtime_projection_refresh = refresh_runtime_topology_projection()

        stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          after_upsert_edges: after_upsert_edges,
          after_prune_edges: after_prune_edges,
          same_port_demotions: demotion_result,
          telemetry_refresh: telemetry_result,
          runtime_projection_refresh: runtime_projection_refresh,
          stale_cutoff: stale_cutoff,
          self_heal_result: self_heal_result,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:completed, stats)
        Logger.info("canonical_topology_rebuild_stats #{inspect(stats)}")
        {:ok, Map.put(stats, :prune_result, prune_result)}

      {:error, reason} ->
        Logger.warning("Canonical topology rebuild failed: #{inspect(reason)}")

        failure_stats = %{
          before_edges: before_edges,
          mapper_evidence_edges: mapper_evidence_edges,
          same_port_demotions: :skipped,
          stale_cutoff: stale_cutoff,
          lock_skipped: false
        }

        emit_canonical_rebuild_telemetry(:failed, failure_stats, reason)
        {:error, reason, failure_stats}
    end
  end

  defp lock_skipped_rebuild_stats do
    before_edges = canonical_edge_count()
    mapper_evidence_edges = mapper_evidence_edge_count()

    %{
      before_edges: before_edges,
      mapper_evidence_edges: mapper_evidence_edges,
      after_upsert_edges: before_edges,
      after_prune_edges: before_edges,
      same_port_demotions: :skipped,
      telemetry_refresh: :skipped,
      stale_cutoff: Utils.stale_cutoff_iso8601(),
      self_heal_result: %{status: :skipped},
      prune_result: :skipped,
      lock_skipped: true
    }
  end

  defp refresh_runtime_topology_projection do
    case RuntimeTopologyProjection.refresh_from_graph() do
      {:ok, summary} ->
        summary

      {:error, reason} ->
        Logger.warning("Runtime topology projection refresh failed: #{inspect(reason)}")
        %{status: :failed, reason: inspect(reason)}
    end
  end

  defp reconcile_competing_same_port_canonical_edges do
    case Graph.query(competing_same_port_canonical_edges_query()) do
      {:ok, edges} ->
        edge_map = Map.new(edges, &{canonical_edge_key(&1), &1})

        demotions =
          edges
          |> Enum.flat_map(&edge_port_conflicts/1)
          |> Enum.group_by(fn {port_key, _edge_key} -> port_key end, fn {_port_key, edge_key} ->
            edge_key
          end)
          |> Enum.flat_map(fn {_port_key, edge_keys} ->
            demotions_for_port_group(edge_keys, edge_map)
          end)
          |> Enum.uniq()

        Enum.each(demotions, &demote_canonical_edge_to_attachment/1)
        {:ok, length(demotions)}

      {:error, reason} ->
        Logger.warning("Canonical same-port reconciliation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp competing_same_port_canonical_edges_query do
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND coalesce(r.relation_type, '') = 'CONNECTS_TO'
      AND coalesce(r.evidence_class, '') = 'direct-physical'
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      pair_support_rank: coalesce(r.pair_support_rank, 0),
      local_if_index_ab: coalesce(r.local_if_index_ab, r.local_if_index),
      local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, ''),
      local_if_index_ba: coalesce(r.local_if_index_ba, r.neighbor_if_index),
      local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, '')
    }
    """
  end

  defp edge_port_conflicts(%{} = edge) do
    edge_key = canonical_edge_key(edge)

    [
      canonical_port_key(
        Map.get(edge, "src_id"),
        Map.get(edge, "local_if_index_ab"),
        Map.get(edge, "local_if_name_ab")
      ),
      canonical_port_key(
        Map.get(edge, "dst_id"),
        Map.get(edge, "local_if_index_ba"),
        Map.get(edge, "local_if_name_ba")
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, edge_key})
  end

  defp edge_port_conflicts(_), do: []

  defp demotions_for_port_group(edge_keys, edge_map)
       when is_list(edge_keys) and is_map(edge_map) do
    group =
      edge_keys
      |> Enum.uniq()
      |> Enum.map(&Map.get(edge_map, &1))
      |> Enum.reject(&is_nil/1)

    if length(group) > 1 and Enum.any?(group, &(pair_support_rank(&1) > 0)) do
      group
      |> Enum.filter(&(pair_support_rank(&1) == 0))
      |> Enum.map(&canonical_edge_key/1)
    else
      []
    end
  end

  defp demotions_for_port_group(_edge_keys, _edge_map), do: []

  defp demote_canonical_edge_to_attachment({src_id, dst_id})
       when is_binary(src_id) and is_binary(dst_id) do
    cypher = """
    MATCH (a:Device {id: '#{Graph.escape(src_id)}'})-[r:CANONICAL_TOPOLOGY]->(b:Device {id: '#{Graph.escape(dst_id)}'})
    SET r.relation_type = 'ATTACHED_TO'
    SET r.evidence_class = 'endpoint-attachment'
    SET r.confidence_tier = 'medium'
    SET r.confidence_score = CASE WHEN coalesce(r.confidence_score, 0) > 78 THEN r.confidence_score ELSE 78 END
    SET r.confidence_reason = 'shared_segment_via_uplink'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Canonical edge demotion failed: #{inspect(reason)}")
    end
  end

  defp demote_canonical_edge_to_attachment(_edge_key), do: :ok

  defp canonical_edge_key(%{} = edge) do
    src_id = Map.get(edge, "src_id")
    dst_id = Map.get(edge, "dst_id")

    if is_binary(src_id) and is_binary(dst_id), do: {src_id, dst_id}
  end

  defp canonical_edge_key(_), do: nil

  defp canonical_port_key(device_id, if_index, if_name) do
    device_id = Utils.non_blank(device_id)
    if_name = Utils.non_blank(if_name)
    if_index = Utils.value_to_non_negative_int(if_index)

    cond do
      is_binary(device_id) and is_integer(if_index) and if_index > 0 ->
        {device_id, {:ifindex, if_index}}

      is_binary(device_id) and is_binary(if_name) ->
        {device_id, {:ifname, if_name}}

      true ->
        nil
    end
  end

  defp pair_support_rank(%{} = edge) do
    edge
    |> Map.get("pair_support_rank")
    |> Utils.value_to_non_negative_int()
    |> Kernel.||(0)
  end

  defp pair_support_rank(_), do: 0

  defp maybe_self_heal_zero_canonical(
         after_prune_edges,
         mapper_evidence_edges,
         stale_cutoff,
         min_canonical_edges
       )
       when is_integer(after_prune_edges) and is_integer(mapper_evidence_edges) and
              is_binary(stale_cutoff) and
              is_integer(min_canonical_edges) do
    if self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges) do
      Logger.warning(
        "Canonical topology self-heal triggered",
        after_prune_edges: after_prune_edges,
        mapper_evidence_edges: mapper_evidence_edges,
        min_canonical_edges: min_canonical_edges
      )

      case Graph.execute(Queries.canonical_rebuild_upsert_query(stale_cutoff)) do
        :ok ->
          healed_edges = canonical_edge_count()
          {healed_edges, %{status: :completed, before: after_prune_edges, after: healed_edges}}

        {:error, reason} ->
          Logger.warning("Canonical topology self-heal failed", reason: inspect(reason))

          {after_prune_edges,
           %{status: :failed, before: after_prune_edges, after: after_prune_edges, reason: reason}}
      end
    else
      {after_prune_edges, %{status: :skipped}}
    end
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, inspect(reason))

  defp prune_stale_canonical_device_links(stale_cutoff) when is_binary(stale_cutoff) do
    prune_cypher = Queries.canonical_rebuild_prune_query(stale_cutoff)

    case Graph.execute(prune_cypher) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Canonical topology stale-edge prune failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp edge_count_from_query(cypher) when is_binary(cypher) do
    case Graph.query(cypher) do
      {:ok, [row | _]} ->
        row
        |> Utils.map_value(:count)
        |> parse_count()

      {:ok, _} ->
        0

      {:error, reason} ->
        Logger.warning("Topology edge count query failed: #{inspect(reason)}")
        0
    end
  end

  defp parse_count(value) when is_integer(value) and value >= 0, do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} when count >= 0 -> count
      _ -> 0
    end
  end

  defp parse_count(_), do: 0
end
