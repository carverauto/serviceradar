defmodule ServiceRadarWebNG.Topology.RuntimeGraph do
  @moduledoc """
  Runtime topology graph cache for God-View.

  AGE remains the canonical source of truth. This process continuously refreshes
  an in-memory topology projection from AGE so snapshot builds do not re-query
  the graph for every request.
  """

  use GenServer

  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Topology.Native

  @default_refresh_ms 5_000
  @default_stale_minutes 180
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
        _ = Native.runtime_graph_ingest_rows(state.graph_ref, rows)
        %{state | last_refresh_at: DateTime.utc_now()}

      _ ->
        state
    end
  end

  defp fetch_topology_links_from_graph do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-topology_stale_minutes() * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    escaped_cutoff = AgeGraph.escape(cutoff)

    cypher = """
    MATCH (a:Device)-[:HAS_INTERFACE]->(ai:Interface)-[r:CONNECTS_TO]->(bi:Interface)<-[:HAS_INTERFACE]-(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND coalesce(r.confidence_tier, 'low') IN ['high', 'medium']
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{escaped_cutoff}')
    RETURN {
      local_device_id: ai.device_id,
      local_device_ip: a.ip,
      local_if_name: ai.name,
      local_if_index: ai.ifindex,
      neighbor_device_id: bi.device_id,
      neighbor_mgmt_addr: b.ip,
      neighbor_system_name: b.name,
      protocol: coalesce(r.protocol, r.source, 'unknown'),
      confidence_tier: coalesce(r.confidence_tier, 'unknown'),
      metadata: {
        source: coalesce(r.source, ''),
        inference: coalesce(r.confidence_reason, ''),
        confidence_tier: coalesce(r.confidence_tier, 'unknown'),
        confidence_score: coalesce(r.confidence_score, 0)
      }
    }
    ORDER BY coalesce(r.last_observed_at, r.observed_at) DESC
    LIMIT #{@max_link_rows}
    """

    case AgeGraph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp decode_row(%{} = row) do
    local_device_id = map_fetch(row, :local_device_id)
    local_device_ip = map_fetch(row, :local_device_ip)
    local_if_name = map_fetch(row, :local_if_name)
    local_if_index = map_fetch(row, :local_if_index)
    neighbor_device_id = map_fetch(row, :neighbor_device_id)
    neighbor_mgmt_addr = map_fetch(row, :neighbor_mgmt_addr)
    neighbor_system_name = map_fetch(row, :neighbor_system_name)
    protocol = map_fetch(row, :protocol)
    confidence_tier = map_fetch(row, :confidence_tier)
    metadata_json = map_fetch(row, :metadata_json) || "{}"

    metadata =
      case Jason.decode(metadata_json || "{}") do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    %{
      local_device_id: blank_to_nil(local_device_id),
      local_device_ip: blank_to_nil(local_device_ip),
      local_if_name: blank_to_nil(local_if_name),
      local_if_index: if(is_integer(local_if_index) and local_if_index >= 0, do: local_if_index, else: nil),
      neighbor_device_id: blank_to_nil(neighbor_device_id),
      neighbor_mgmt_addr: blank_to_nil(neighbor_mgmt_addr),
      neighbor_system_name: blank_to_nil(neighbor_system_name),
      protocol: blank_to_nil(protocol),
      confidence_tier: blank_to_nil(confidence_tier),
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

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp topology_stale_minutes do
    Application.get_env(
      :serviceradar_core,
      :mapper_topology_edge_stale_minutes,
      @default_stale_minutes
    )
  end
end
