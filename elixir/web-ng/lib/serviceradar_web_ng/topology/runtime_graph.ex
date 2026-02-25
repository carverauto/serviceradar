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
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE coalesce(r.relation_type, type(r)) IN ['CONNECTS_TO', 'ATTACHED_TO']
    RETURN {
      local_device_id: a.id,
      local_device_ip: a.ip,
      local_if_name: coalesce(r.local_if_name, ''),
      local_if_index: r.local_if_index,
      neighbor_if_name: coalesce(r.neighbor_if_name, ''),
      neighbor_if_index: r.neighbor_if_index,
      neighbor_device_id: b.id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
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
    neighbor_device_id = map_fetch(row, :neighbor_device_id)
    neighbor_mgmt_addr = map_fetch(row, :neighbor_mgmt_addr)
    neighbor_system_name = map_fetch(row, :neighbor_system_name)
    protocol = map_fetch(row, :protocol)
    confidence_tier = map_fetch(row, :confidence_tier)
    evidence_class = map_fetch(row, :evidence_class)
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
      neighbor_if_name: blank_to_nil(neighbor_if_name),
      neighbor_if_index: parse_ifindex(neighbor_if_index),
      neighbor_device_id: blank_to_nil(neighbor_device_id),
      neighbor_mgmt_addr: blank_to_nil(neighbor_mgmt_addr),
      neighbor_system_name: blank_to_nil(neighbor_system_name),
      protocol: blank_to_nil(protocol),
      confidence_tier: blank_to_nil(confidence_tier),
      evidence_class: blank_to_nil(evidence_class),
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

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default
end
