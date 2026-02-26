defmodule ServiceRadarWebNG.Topology.RuntimeGraph do
  @moduledoc """
  Runtime topology graph cache for God-View.

  AGE remains the canonical source of truth. This process continuously refreshes
  an in-memory topology projection from AGE so snapshot builds do not re-query
  the graph for every request.
  """

  use GenServer
  require Logger

  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Topology.Native

  @default_refresh_ms 5_000
  @max_link_rows 5_000

  @type state :: %{
          graph_ref: term(),
          last_refresh_at: DateTime.t() | nil,
          refresh_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_links() :: {:ok, [map()]}
  def get_links do
    GenServer.call(__MODULE__, :get_links)
  end

  @spec get_graph_ref() :: {:ok, term()}
  def get_graph_ref do
    GenServer.call(__MODULE__, :get_graph_ref)
  end

  @spec refresh_now() :: :ok
  def refresh_now do
    GenServer.cast(__MODULE__, :refresh_now)
  end

  @impl true
  def init(_opts) do
    refresh_ms =
      Application.get_env(
        :serviceradar_web_ng,
        :god_view_runtime_graph_refresh_ms,
        @default_refresh_ms
      )
      |> normalize_positive_int(@default_refresh_ms)

    state = %{graph_ref: Native.runtime_graph_new(), last_refresh_at: nil, refresh_ms: refresh_ms}
    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_links, _from, state) do
    links =
      state.graph_ref
      |> Native.runtime_graph_get_links()
      |> Enum.map(&decode_row/1)

    {:reply, {:ok, links}, state}
  end

  @impl true
  def handle_call(:get_graph_ref, _from, state) do
    {:reply, {:ok, state.graph_ref}, state}
  end

  @impl true
  def handle_cast(:refresh_now, state) do
    {:noreply, refresh_state(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    next = refresh_state(state)
    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, next}
  end

  defp refresh_state(state) do
    case fetch_topology_links_from_graph() do
      {:ok, rows} when is_list(rows) ->
        normalized_rows = normalize_runtime_rows(rows)
        ingested = Native.runtime_graph_ingest_rows(state.graph_ref, normalized_rows)
        Logger.info("runtime_graph_refresh fetched=#{length(rows)} ingested=#{ingested}")
        %{state | last_refresh_at: DateTime.utc_now()}

      {:error, reason} ->
        Logger.warning("runtime_graph_refresh_failed reason=#{inspect(reason)}")
        state

      _ ->
        state
    end
  end

  defp fetch_topology_links_from_graph do
    cypher = topology_links_query()

    case AgeGraph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec topology_links_query() :: String.t()
  def topology_links_query do
    if backend_authoritative_topology_enabled?() do
      authoritative_topology_links_query()
    else
      fallback_topology_links_query()
    end
  end

  defp authoritative_topology_links_query do
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
      AND coalesce(r.relation_type, type(r)) IN ['CONNECTS_TO', 'ATTACHED_TO']
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
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    }
    ORDER BY
      coalesce(r.last_observed_at, r.observed_at) DESC
    LIMIT #{@max_link_rows}
    """
  end

  defp fallback_topology_links_query do
    """
    MATCH (ai:Interface)-[r]->(bi:Interface)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']
      AND ai.device_id IS NOT NULL
      AND bi.device_id IS NOT NULL
      AND ai.device_id <> bi.device_id
    RETURN {
      local_device_id: ai.device_id,
      local_device_ip: coalesce(ai.ip, ''),
      local_if_name: coalesce(ai.name, ''),
      local_if_index: ai.ifindex,
      local_if_name_ab: coalesce(ai.name, ''),
      local_if_index_ab: ai.ifindex,
      local_if_name_ba: coalesce(bi.name, ''),
      local_if_index_ba: bi.ifindex,
      neighbor_if_name: coalesce(bi.name, ''),
      neighbor_if_index: bi.ifindex,
      neighbor_device_id: bi.device_id,
      neighbor_mgmt_addr: coalesce(bi.ip, ''),
      neighbor_system_name: coalesce(bi.system_name, ''),
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
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    }
    ORDER BY
      coalesce(r.last_observed_at, r.observed_at) DESC
    LIMIT #{@max_link_rows}
    """
  end

  defp backend_authoritative_topology_enabled? do
    Application.get_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology, true)
  end

  defp normalize_runtime_rows(rows) when is_list(rows) do
    Enum.reduce(rows, [], fn row, acc ->
      case normalize_runtime_row(row) do
        nil -> acc
        normalized -> [normalized | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_runtime_row(%{} = row) do
    row
    |> unwrap_single_map_value()
    |> maybe_string_key("local_device_id", "local_device_ip", "neighbor_device_id")
  end

  defp normalize_runtime_row(_), do: nil

  defp unwrap_single_map_value(%{} = map) do
    if map_size(map) == 1 do
      [{_k, v}] = Map.to_list(map)
      if is_map(v), do: v, else: map
    else
      map
    end
  end

  defp maybe_string_key(%{} = map, k1, k2, k3) do
    cond do
      map_has_key_string_or_atom?(map, k1) ->
        map

      map_has_key_string_or_atom?(map, k2) ->
        map

      map_has_key_string_or_atom?(map, k3) ->
        map

      true ->
        nil
    end
  end

  defp map_has_key_string_or_atom?(%{} = map, key) when is_binary(key) do
    Map.has_key?(map, key) or
      Enum.any?(Map.keys(map), fn
        k when is_atom(k) -> Atom.to_string(k) == key
        _ -> false
      end)
  end

  defp decode_row(%{} = row) do
    local_device_id = map_fetch(row, :local_device_id)
    local_device_ip = map_fetch(row, :local_device_ip)
    local_if_name = map_fetch(row, :local_if_name)
    local_if_index = map_fetch(row, :local_if_index)
    neighbor_if_name = map_fetch(row, :neighbor_if_name)
    neighbor_if_index = map_fetch(row, :neighbor_if_index)
    local_if_name_ab = map_fetch(row, :local_if_name_ab)
    local_if_index_ab = map_fetch(row, :local_if_index_ab)
    local_if_name_ba = map_fetch(row, :local_if_name_ba)
    local_if_index_ba = map_fetch(row, :local_if_index_ba)
    neighbor_device_id = map_fetch(row, :neighbor_device_id)
    neighbor_mgmt_addr = map_fetch(row, :neighbor_mgmt_addr)
    neighbor_system_name = map_fetch(row, :neighbor_system_name)
    protocol = map_fetch(row, :protocol)
    confidence_tier = map_fetch(row, :confidence_tier)
    confidence_reason = map_fetch(row, :confidence_reason)
    evidence_class = map_fetch(row, :evidence_class)
    flow_pps = parse_non_negative_int(map_fetch(row, :flow_pps))
    flow_bps = parse_non_negative_int(map_fetch(row, :flow_bps))
    capacity_bps = parse_non_negative_int(map_fetch(row, :capacity_bps))
    flow_pps_ab = parse_non_negative_int(map_fetch(row, :flow_pps_ab))
    flow_pps_ba = parse_non_negative_int(map_fetch(row, :flow_pps_ba))
    flow_bps_ab = parse_non_negative_int(map_fetch(row, :flow_bps_ab))
    flow_bps_ba = parse_non_negative_int(map_fetch(row, :flow_bps_ba))
    telemetry_source = map_fetch(row, :telemetry_source)
    telemetry_eligible = parse_bool(map_fetch(row, :telemetry_eligible))
    telemetry_observed_at = map_fetch(row, :telemetry_observed_at)
    metadata_value = map_fetch(row, :metadata) || map_fetch(row, :metadata_json) || %{}

    metadata =
      cond do
        is_map(metadata_value) ->
          metadata_value

        is_binary(metadata_value) ->
          case Jason.decode(metadata_value) do
            {:ok, value} when is_map(value) -> value
            _ -> %{}
          end

        true ->
          %{}
      end

    %{
      local_device_id: blank_to_nil(local_device_id),
      local_device_ip: blank_to_nil(local_device_ip),
      local_if_name: blank_to_nil(local_if_name),
      local_if_index: parse_ifindex(local_if_index),
      local_if_name_ab: blank_to_nil(local_if_name_ab),
      local_if_index_ab: parse_ifindex(local_if_index_ab),
      local_if_name_ba: blank_to_nil(local_if_name_ba),
      local_if_index_ba: parse_ifindex(local_if_index_ba),
      neighbor_if_name: blank_to_nil(neighbor_if_name),
      neighbor_if_index: parse_ifindex(neighbor_if_index),
      neighbor_device_id: blank_to_nil(neighbor_device_id),
      neighbor_mgmt_addr: blank_to_nil(neighbor_mgmt_addr),
      neighbor_system_name: blank_to_nil(neighbor_system_name),
      protocol: blank_to_nil(protocol),
      confidence_tier: blank_to_nil(confidence_tier),
      confidence_reason: blank_to_nil(confidence_reason),
      evidence_class: blank_to_nil(evidence_class),
      flow_pps: flow_pps,
      flow_bps: flow_bps,
      capacity_bps: capacity_bps,
      flow_pps_ab: flow_pps_ab,
      flow_pps_ba: flow_pps_ba,
      flow_bps_ab: flow_bps_ab,
      flow_bps_ba: flow_bps_ba,
      telemetry_eligible: telemetry_eligible,
      telemetry_source: blank_to_nil(telemetry_source),
      telemetry_observed_at: blank_to_nil(telemetry_observed_at),
      metadata: metadata
    }
  end

  defp decode_row(_), do: %{}

  defp map_fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil

  defp parse_ifindex(value) when is_integer(value) and value >= 0, do: value

  defp parse_ifindex(value) when is_float(value) do
    rounded = trunc(Float.round(value))
    if rounded >= 0, do: rounded, else: nil
  end

  defp parse_ifindex(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_ifindex(_), do: nil

  defp parse_non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp parse_non_negative_int(_), do: 0

  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when is_integer(value), do: value > 0

  defp parse_bool(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "true" -> true
      "1" -> true
      _ -> false
    end
  end

  defp parse_bool(_), do: false

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default
end
