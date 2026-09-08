defmodule ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection do
  @moduledoc """
  Materialized SQL read-model for God-View runtime topology links.

  Apache AGE remains canonical. This module projects the render-ready AGE topology rows into a
  small SQL table after topology rebuilds so web-ng refreshes do not repeatedly traverse AGE.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Graph
  alias ServiceRadar.Repo

  @max_backbone_link_rows 5_000
  @max_attachment_link_rows 2_000
  @default_read_limit @max_backbone_link_rows + @max_attachment_link_rows
  @projection_name "runtime_topology_links"

  @type refresh_result :: {:ok, %{rows: non_neg_integer()}} | {:error, term()}

  @doc """
  AGE query used to build the SQL projection.
  """
  @spec graph_projection_query() :: String.t()
  def graph_projection_query do
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
      AND (
        toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON']
        OR (coalesce(r.relation_type, '') = '' AND toLower(coalesce(r.evidence_class, '')) IN ['direct', 'direct-physical', 'direct-logical', 'hosted-virtual'])
      )
    WITH a, b, r
    ORDER BY coalesce(r.last_observed_at, r.observed_at) DESC,
      a.id ASC,
      b.id ASC,
      toUpper(coalesce(r.relation_type, type(r), '')) ASC,
      toLower(coalesce(r.evidence_class, '')) ASC,
      coalesce(r.local_if_index, -1) ASC,
      coalesce(r.local_if_name, '') ASC,
      coalesce(r.neighbor_if_index, -1) ASC,
      coalesce(r.neighbor_if_name, '') ASC,
      coalesce(r.protocol, r.source, 'unknown') ASC,
      coalesce(r.link_key, '') ASC
    LIMIT #{@max_backbone_link_rows}
    RETURN {
      local_device_id: a.id,
      local_device_ip: a.ip,
      local_if_name: coalesce(r.local_if_name, ''),
      local_if_index: r.local_if_index,
      local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, ''),
      local_if_index_ab: coalesce(r.local_if_index_ab, r.local_if_index),
      local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, ''),
      local_if_index_ba: coalesce(r.local_if_index_ba, r.neighbor_if_index),
      neighbor_if_name: coalesce(r.neighbor_if_name, ''),
      neighbor_if_index: r.neighbor_if_index,
      neighbor_device_id: b.id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      observed_at: coalesce(r.last_observed_at, r.observed_at, ''),
      flow_pps: coalesce(r.flow_pps, 0),
      flow_bps: coalesce(r.flow_bps, 0),
      capacity_bps: coalesce(r.capacity_bps, 0),
      flow_pps_ab: coalesce(r.flow_pps_ab, 0),
      flow_pps_ba: coalesce(r.flow_pps_ba, 0),
      flow_bps_ab: coalesce(r.flow_bps_ab, 0),
      flow_bps_ba: coalesce(r.flow_bps_ba, 0),
      telemetry_eligible: coalesce(
        r.telemetry_eligible,
        CASE
          WHEN coalesce(r.flow_pps, 0) > 0 OR coalesce(r.flow_bps, 0) > 0 THEN true
          WHEN coalesce(r.flow_pps_ab, 0) > 0 OR coalesce(r.flow_pps_ba, 0) > 0 THEN true
          WHEN coalesce(r.flow_bps_ab, 0) > 0 OR coalesce(r.flow_bps_ba, 0) > 0 THEN true
          ELSE false
        END
      ),
      telemetry_source: coalesce(r.telemetry_source, 'none'),
      telemetry_observed_at: coalesce(r.telemetry_observed_at, ''),
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
      confidence_reason: coalesce(r.confidence_reason, ''),
      evidence_class: coalesce(r.evidence_class, ''),
      metadata: {
        relation_type: coalesce(r.relation_type, type(r)),
        source: coalesce(r.source, ''),
        inference: coalesce(r.confidence_reason, ''),
        evidence_class: coalesce(r.evidence_class, ''),
        topology_plane: CASE
          WHEN toUpper(coalesce(r.relation_type, '')) = 'LOGICAL_PEER' THEN 'logical'
          WHEN toUpper(coalesce(r.relation_type, '')) = 'HOSTED_ON' THEN 'hosted'
          ELSE 'backbone'
        END,
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    } AS row
    UNION ALL
    MATCH (ai:Interface)-[r]->(bi:Interface)
    MATCH (a:Device {id: ai.device_id})
    MATCH (b:Device {id: bi.device_id})
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['ATTACHED_TO', 'OBSERVED_TO']
      AND ai.device_id IS NOT NULL
      AND bi.device_id IS NOT NULL
      AND ai.device_id STARTS WITH 'sr:'
      AND bi.device_id STARTS WITH 'sr:'
      AND ai.device_id <> bi.device_id
    WITH a, b, ai, bi, r
    ORDER BY coalesce(r.last_observed_at, r.observed_at) DESC,
      ai.device_id ASC,
      bi.device_id ASC,
      type(r) ASC,
      toLower(coalesce(r.evidence_class, '')) ASC,
      coalesce(ai.ifindex, -1) ASC,
      coalesce(ai.name, '') ASC,
      coalesce(bi.ifindex, -1) ASC,
      coalesce(bi.name, '') ASC,
      coalesce(r.protocol, r.source, 'unknown') ASC,
      coalesce(ai.id, '') ASC,
      coalesce(bi.id, '') ASC
    LIMIT #{@max_attachment_link_rows}
    RETURN {
      local_device_id: ai.device_id,
      local_device_ip: a.ip,
      local_if_name: coalesce(ai.name, ''),
      local_if_index: ai.ifindex,
      local_if_name_ab: coalesce(ai.name, ''),
      local_if_index_ab: ai.ifindex,
      local_if_name_ba: coalesce(bi.name, ''),
      local_if_index_ba: bi.ifindex,
      neighbor_if_name: coalesce(bi.name, ''),
      neighbor_if_index: bi.ifindex,
      neighbor_device_id: bi.device_id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      observed_at: coalesce(r.last_observed_at, r.observed_at, ''),
      flow_pps: 0,
      flow_bps: 0,
      capacity_bps: 0,
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_eligible: false,
      telemetry_source: 'none',
      telemetry_observed_at: coalesce(r.last_observed_at, r.observed_at, ''),
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
      confidence_reason: coalesce(r.confidence_reason, ''),
      evidence_class: coalesce(r.evidence_class, 'endpoint-attachment'),
      metadata: {
        relation_type: type(r),
        source: coalesce(r.source, r.ingestor, 'mapper_topology_v1'),
        inference: coalesce(r.confidence_reason, ''),
        evidence_class: coalesce(r.evidence_class, 'endpoint-attachment'),
        topology_plane: 'attachment',
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    } AS row
    UNION ALL
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
      AND a.id <> b.id
      AND toUpper(coalesce(r.relation_type, '')) = 'ATTACHED_TO'
      AND toLower(coalesce(r.evidence_class, '')) = 'inferred-segment'
    WITH a, b, r
    ORDER BY coalesce(r.last_observed_at, r.observed_at) DESC,
      a.id ASC,
      b.id ASC,
      toUpper(coalesce(r.relation_type, type(r), '')) ASC,
      toLower(coalesce(r.evidence_class, '')) ASC,
      coalesce(r.local_if_index, -1) ASC,
      coalesce(r.local_if_name, '') ASC,
      coalesce(r.neighbor_if_index, -1) ASC,
      coalesce(r.neighbor_if_name, '') ASC,
      coalesce(r.protocol, r.source, 'unknown') ASC,
      coalesce(r.link_key, '') ASC
    LIMIT #{@max_attachment_link_rows}
    RETURN {
      local_device_id: a.id,
      local_device_ip: a.ip,
      local_if_name: coalesce(r.local_if_name, ''),
      local_if_index: r.local_if_index,
      local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, ''),
      local_if_index_ab: r.local_if_index_ab,
      local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, ''),
      local_if_index_ba: r.local_if_index_ba,
      neighbor_if_name: coalesce(r.neighbor_if_name, ''),
      neighbor_if_index: r.neighbor_if_index,
      neighbor_device_id: b.id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      observed_at: coalesce(r.last_observed_at, r.observed_at, ''),
      flow_pps: 0,
      flow_bps: 0,
      capacity_bps: 0,
      flow_pps_ab: 0,
      flow_pps_ba: 0,
      flow_bps_ab: 0,
      flow_bps_ba: 0,
      telemetry_eligible: false,
      telemetry_source: 'none',
      telemetry_observed_at: coalesce(r.last_observed_at, r.observed_at, ''),
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
      confidence_reason: coalesce(r.confidence_reason, ''),
      evidence_class: coalesce(r.evidence_class, 'inferred-segment'),
      metadata: {
        relation_type: coalesce(r.relation_type, type(r)),
        source: coalesce(r.source, 'inferred-segment'),
        inference: coalesce(r.confidence_reason, ''),
        evidence_class: coalesce(r.evidence_class, 'inferred-segment'),
        topology_plane: 'attachment',
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    } AS row
    """
  end

  @doc """
  Refreshes the SQL projection from AGE.
  """
  @spec refresh_from_graph(keyword()) :: refresh_result()
  def refresh_from_graph(opts \\ []) do
    graph = Keyword.get(opts, :graph, Graph)
    repo = Keyword.get(opts, :repo, Repo)
    input_hash = Keyword.get(opts, :input_hash, nil)

    with {:ok, graph_rows} <- graph.query(graph_projection_query()) do
      rows = projection_attrs_from_graph_rows(graph_rows)

      transaction = fn ->
        now = DateTime.utc_now()
        delete_query = from(l in "runtime_topology_links", prefix: "platform")
        repo.delete_all(delete_query)

        row_count = insert_projection_rows(repo, rows)
        upsert_projection_meta(repo, row_count, now, input_hash)

        %{rows: row_count}
      end

      case repo.transaction(transaction) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Reads cached runtime topology rows from the SQL projection.
  """
  @spec read_cached_links(keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_cached_links(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    limit =
      opts
      |> Keyword.get(:limit, @default_read_limit)
      |> normalize_positive_int(@default_read_limit)

    query =
      from(l in "runtime_topology_links",
        prefix: "platform",
        order_by: [
          asc:
            fragment(
              "CASE ? WHEN 'backbone' THEN 0 WHEN 'logical' THEN 1 WHEN 'hosted' THEN 2 WHEN 'attachment' THEN 3 ELSE 4 END",
              l.topology_plane
            ),
          desc_nulls_last: l.observed_at,
          desc: l.inserted_at,
          asc: l.local_device_id,
          asc: l.neighbor_device_id,
          asc: l.relation_type,
          asc: l.evidence_class,
          asc: fragment("?::text", l.row),
          asc: l.id
        ],
        limit: ^limit,
        select: l.row
      )

    rows = repo.all(query)

    cond do
      rows != [] ->
        {:ok, rows}

      projection_initialized?(repo) ->
        {:ok, []}

      true ->
        {:error, :projection_uninitialized}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec projection_attrs_from_graph_rows([map()]) :: [map()]
  def projection_attrs_from_graph_rows(rows) when is_list(rows) do
    now = DateTime.utc_now()

    rows
    |> Enum.map(&unwrap_graph_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&projection_attrs(&1, now))
  end

  def projection_attrs_from_graph_rows(_rows), do: []

  defp projection_attrs(row, now) when is_map(row) do
    metadata = map_value(row, "metadata", :metadata) || %{}
    local_device_id = map_value(row, "local_device_id", :local_device_id)
    neighbor_device_id = map_value(row, "neighbor_device_id", :neighbor_device_id)

    with true <- non_blank?(local_device_id),
         true <- non_blank?(neighbor_device_id),
         true <- local_device_id != neighbor_device_id do
      topology_plane = topology_plane(row, metadata)

      [
        %{
          topology_plane: topology_plane,
          local_device_id: local_device_id,
          neighbor_device_id: neighbor_device_id,
          relation_type: map_value(metadata, "relation_type", :relation_type),
          evidence_class:
            map_value(row, "evidence_class", :evidence_class) ||
              map_value(metadata, "evidence_class", :evidence_class),
          observed_at: parse_datetime(map_value(row, "observed_at", :observed_at)),
          row: row,
          inserted_at: now,
          updated_at: now
        }
      ]
    else
      _ -> []
    end
  end

  defp projection_attrs(_row, _now), do: []

  defp insert_projection_rows(_repo, []), do: 0

  defp insert_projection_rows(repo, rows) do
    {count, _} =
      repo.insert_all("runtime_topology_links", rows,
        prefix: "platform",
        returning: false
      )

    count
  end

  # input_hash defaults to nil so other callers keep working; it is the canonical
  # rebuild's mapper-evidence fingerprint (see CanonicalRebuild). Persisting it
  # here — in the same insert_all that records refreshed_at/row_count, at the end
  # of a successful rebuild — makes the skip-guard durable across restarts and
  # shared across replicas, and advances the hash only after a successful rebuild.
  # When input_hash is nil (non-rebuild caller) we leave the stored hash untouched
  # rather than clobbering it to nil, which would force the next rebuild to
  # fail-open even when the topology is unchanged.
  defp upsert_projection_meta(repo, row_count, now, input_hash) do
    base = %{
      projection_name: @projection_name,
      refreshed_at: now,
      row_count: row_count,
      inserted_at: now,
      updated_at: now
    }

    {attrs, replace_fields} =
      if is_binary(input_hash) do
        {Map.merge(base, %{input_hash: input_hash, input_hashed_at: now}),
         [:refreshed_at, :row_count, :updated_at, :input_hash, :input_hashed_at]}
      else
        {base, [:refreshed_at, :row_count, :updated_at]}
      end

    repo.insert_all(
      "runtime_topology_projection_meta",
      [attrs],
      prefix: "platform",
      conflict_target: [:projection_name],
      on_conflict: {:replace, replace_fields},
      returning: false
    )
  end

  defp projection_initialized?(repo) do
    query =
      from(m in "runtime_topology_projection_meta",
        prefix: "platform",
        where: m.projection_name == ^@projection_name,
        select: 1,
        limit: 1
      )

    repo.exists?(query)
  end

  defp unwrap_graph_row(%{"row" => %{} = row}), do: row
  defp unwrap_graph_row(%{row: %{} = row}), do: row

  defp unwrap_graph_row(%{} = map) do
    if map_size(map) == 1 do
      [{_key, value}] = Map.to_list(map)
      if is_map(value), do: value, else: map
    else
      map
    end
  end

  defp unwrap_graph_row(_row), do: nil

  defp topology_plane(row, metadata) do
    map_value(metadata, "topology_plane", :topology_plane) ||
      relation_type_to_plane(map_value(metadata, "relation_type", :relation_type)) ||
      relation_type_to_plane(map_value(row, "relation_type", :relation_type)) ||
      "unknown"
  end

  defp relation_type_to_plane(relation_type) when is_binary(relation_type) do
    case String.upcase(relation_type) do
      "LOGICAL_PEER" -> "logical"
      "HOSTED_ON" -> "hosted"
      "ATTACHED_TO" -> "attachment"
      "OBSERVED_TO" -> "attachment"
      "CONNECTS_TO" -> "backbone"
      _ -> nil
    end
  end

  defp relation_type_to_plane(_relation_type), do: nil

  defp map_value(%{} = map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp map_value(_map, _string_key, _atom_key), do: nil

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false

  defp parse_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp parse_datetime(""), do: nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default
end
