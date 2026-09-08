defmodule ServiceRadarWebNG.Topology.RuntimeGraph do
  @moduledoc """
  Runtime topology graph cache for God-View.

  AGE remains the canonical source of truth. This process continuously refreshes
  an in-memory topology projection from AGE so snapshot builds do not re-query
  the graph for every request.
  """

  use GenServer

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Topology.Native

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  # Published once per process lifetime in `init/1` so readers never have to enter this
  # GenServer. Reads are the hot path (every God-View snapshot build); the refresh handler
  # holds the process for the whole projection/AGE round trip.
  @graph_ref_key {__MODULE__, :graph_ref}

  @default_refresh_ms 30_000
  @max_backbone_link_rows 5_000
  @max_attachment_link_rows 2_000
  @max_inferred_segment_link_rows 2_000
  @max_virtualization_link_rows 5_000

  @type state :: %{
          graph_ref: term(),
          last_refresh_at: DateTime.t() | nil,
          last_refresh_started_at_ms: integer() | nil,
          refresh_ms: pos_integer(),
          min_refresh_ms: pos_integer(),
          auto_refresh?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read the cached topology links.

  Reads the published graph reference directly rather than calling this GenServer.
  `Native.runtime_graph_get_links/1` takes only a read lock, and an ingest replaces the
  whole vector under a write lock held for the assignment alone -- so a reader observes
  either the previous or the next snapshot, never a partial one. Going through the
  process instead would queue every reader behind `handle_info(:refresh, ...)`, which
  performs the projection/AGE round trip inline; with `GenServer.call/2`'s default 5s
  that surfaced as a timeout on the God-View snapshot path.

  Falls back to the process only when no reference has been published yet.
  """
  @spec get_links() :: {:ok, [map()]}
  def get_links do
    case published_graph_ref() do
      {:ok, graph_ref} ->
        {:ok, graph_ref |> Native.runtime_graph_get_links() |> decode_runtime_rows()}

      :error ->
        GenServer.call(__MODULE__, :get_links)
    end
  end

  @spec get_graph_ref() :: {:ok, term()}
  def get_graph_ref do
    case published_graph_ref() do
      {:ok, graph_ref} -> {:ok, graph_ref}
      :error -> GenServer.call(__MODULE__, :get_graph_ref)
    end
  end

  defp published_graph_ref do
    case :persistent_term.get(@graph_ref_key, :error) do
      :error -> :error
      graph_ref -> {:ok, graph_ref}
    end
  end

  # One write per process lifetime, so the global scan `:persistent_term.put/2` triggers is
  # paid at boot and on the rare supervisor restart. The term is deliberately NOT erased on
  # exit: the resource stays alive through the reference, so a reader racing a restart gets
  # the last known links instead of a `:noproc`, and `init/1` overwrites it moments later.
  defp publish_graph_ref(graph_ref) do
    :persistent_term.put(@graph_ref_key, graph_ref)
    graph_ref
  end

  @spec refresh_now() :: :ok
  def refresh_now do
    GenServer.cast(__MODULE__, :refresh_now)
  end

  @spec refresh_now_sync() :: :ok
  def refresh_now_sync do
    GenServer.call(__MODULE__, :refresh_now_sync, 30_000)
  end

  @impl true
  def init(_opts) do
    refresh_ms =
      :serviceradar_web_ng
      |> Application.get_env(
        :god_view_runtime_graph_refresh_ms,
        @default_refresh_ms
      )
      |> normalize_positive_int(@default_refresh_ms)

    min_refresh_ms =
      :serviceradar_web_ng
      |> Application.get_env(:god_view_runtime_graph_min_refresh_ms, refresh_ms)
      |> normalize_positive_int(refresh_ms)

    auto_refresh? =
      Application.get_env(:serviceradar_web_ng, :god_view_runtime_graph_auto_refresh, true) ==
        true

    state = %{
      graph_ref: publish_graph_ref(Native.runtime_graph_new()),
      last_refresh_at: nil,
      last_refresh_started_at_ms: nil,
      refresh_ms: refresh_ms,
      min_refresh_ms: min_refresh_ms,
      auto_refresh?: auto_refresh?
    }

    if auto_refresh?, do: send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_links, _from, state) do
    links =
      state.graph_ref
      |> Native.runtime_graph_get_links()
      |> decode_runtime_rows()

    {:reply, {:ok, links}, state}
  end

  @impl true
  def handle_call(:get_graph_ref, _from, state) do
    {:reply, {:ok, state.graph_ref}, state}
  end

  @impl true
  def handle_call(:refresh_now_sync, _from, state) do
    {:reply, :ok, refresh_state(state, force?: true)}
  end

  @impl true
  def handle_cast(:refresh_now, state) do
    {:noreply, refresh_state(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    next = refresh_state(state)

    if next.auto_refresh? do
      Process.send_after(self(), :refresh, next.refresh_ms)
    end

    {:noreply, next}
  end

  defp refresh_state(state, opts \\ []) do
    now_ms = System.monotonic_time(:millisecond)

    if Keyword.get(opts, :force?, false) or refresh_due?(state, now_ms) do
      state
      |> Map.put(:last_refresh_started_at_ms, now_ms)
      |> do_refresh_state()
    else
      state
    end
  end

  @doc false
  @spec refresh_due?(state(), integer()) :: boolean()
  def refresh_due?(%{last_refresh_started_at_ms: nil}, _now_ms), do: true

  def refresh_due?(%{last_refresh_started_at_ms: last_ms, min_refresh_ms: min_ms}, now_ms)
      when is_integer(last_ms) and is_integer(min_ms) and is_integer(now_ms) do
    now_ms - last_ms >= min_ms
  end

  def refresh_due?(_state, _now_ms), do: true

  defp do_refresh_state(state) do
    case fetch_topology_links_from_graph() do
      {:ok, rows} when is_list(rows) ->
        normalized_rows = normalize_runtime_rows(rows)
        ingested = Native.runtime_graph_ingest_rows(state.graph_ref, normalized_rows)
        backbone_rows = Enum.count(normalized_rows, &backbone_runtime_row?/1)
        attachment_rows = Enum.count(normalized_rows, &attachment_runtime_row?/1)

        Logger.info(
          "runtime_graph_refresh fetched=#{length(rows)} normalized=#{length(normalized_rows)} dropped=#{max(length(rows) - length(normalized_rows), 0)} ingested=#{ingested} backbone=#{backbone_rows} attachment=#{attachment_rows}"
        )

        %{state | last_refresh_at: DateTime.utc_now()}

      {:error, reason} ->
        Logger.warning("runtime_graph_refresh_failed reason=#{inspect(reason)}")
        state
    end
  end

  defp fetch_topology_links_from_graph do
    case projection_read_action(fetch_projected_topology_links()) do
      {:projected, rows} ->
        fetch_topology_links_with_virtualization(rows)

      :fallback_uninitialized ->
        fetch_topology_links_from_age()

      {:fallback_error, reason} ->
        Logger.warning("runtime_graph_projection_read_failed reason=#{inspect(reason)}")
        fetch_topology_links_from_age()
    end
  rescue
    error -> {:error, error}
  end

  defp fetch_projected_topology_links do
    RuntimeTopologyProjection.read_cached_links(
      repo: Repo,
      limit:
        @max_backbone_link_rows + @max_attachment_link_rows +
          @max_inferred_segment_link_rows
    )
  end

  @doc false
  @spec projection_read_action({:ok, list()} | {:error, term()}) ::
          {:projected, list()} | :fallback_uninitialized | {:fallback_error, term()}
  def projection_read_action({:ok, rows}) when is_list(rows), do: {:projected, rows}
  def projection_read_action({:error, :projection_uninitialized}), do: :fallback_uninitialized
  def projection_read_action({:error, reason}), do: {:fallback_error, reason}

  defp fetch_topology_links_from_age do
    case AgeGraph.query(topology_links_query()) do
      {:ok, graph_rows} when is_list(graph_rows) ->
        fetch_topology_links_with_virtualization(graph_rows)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_topology_links_with_virtualization(rows) when is_list(rows) do
    case fetch_virtualization_links_from_inventory() do
      {:ok, virtualization_rows} when is_list(virtualization_rows) ->
        {:ok, rows ++ virtualization_rows}

      {:error, reason} ->
        Logger.warning("runtime_graph_virtualization_inventory_failed reason=#{inspect(reason)}")
        {:ok, rows}
    end
  end

  @doc false
  @spec topology_links_query() :: String.t()
  def topology_links_query do
    RuntimeTopologyProjection.graph_projection_query()
  end

  @doc false
  @spec topology_diagnostics_query() :: String.t()
  def topology_diagnostics_query do
    """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    RETURN {
      canonical_edges: count(r),
      backbone_candidates: sum(CASE
        WHEN toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON'] THEN 1
        WHEN coalesce(r.relation_type, '') = ''
          AND toLower(coalesce(r.evidence_class, '')) IN ['direct', 'direct-physical', 'direct-logical', 'hosted-virtual'] THEN 1
        ELSE 0
      END),
      attachment_candidates: sum(CASE
        WHEN toUpper(coalesce(r.relation_type, '')) IN ['ATTACHED_TO', 'OBSERVED_TO'] THEN 1
        WHEN coalesce(r.relation_type, '') = ''
          AND toLower(coalesce(r.evidence_class, '')) IN ['endpoint-attachment', 'observed-only'] THEN 1
        ELSE 0
      END),
      missing_relation_type: sum(CASE WHEN coalesce(r.relation_type, '') = '' THEN 1 ELSE 0 END),
      missing_evidence_class: sum(CASE WHEN coalesce(r.evidence_class, '') = '' THEN 1 ELSE 0 END),
      missing_endpoint_ids: sum(CASE WHEN a.id IS NULL OR b.id IS NULL THEN 1 ELSE 0 END),
      non_canonical_endpoint_ids: sum(CASE
        WHEN a.id IS NULL OR b.id IS NULL THEN 0
        WHEN NOT a.id STARTS WITH 'sr:' OR NOT b.id STARTS WITH 'sr:' THEN 1
        ELSE 0
      END),
      missing_observed_at: sum(CASE
        WHEN r.last_observed_at IS NULL AND r.observed_at IS NULL THEN 1
        ELSE 0
      END)
    } AS diagnostics
    """
  end

  @doc false
  @spec diagnostics() :: {:ok, map()} | {:error, term()}
  def diagnostics do
    case AgeGraph.query(topology_diagnostics_query()) do
      {:ok, [%{} = row | _]} ->
        {:ok, row |> unwrap_single_map_value() |> atomize_diagnostics()}

      {:ok, []} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec virtualization_inventory_links_query() :: String.t()
  def virtualization_inventory_links_query do
    """
    SELECT jsonb_build_object(
      'local_device_id', h.device_uid,
      'local_device_ip', hd.ip,
      'local_if_name', 'hosted-guests',
      'local_if_index', NULL,
      'local_if_name_ab', 'hosted-guests',
      'local_if_index_ab', NULL,
      'local_if_name_ba', '',
      'local_if_index_ba', NULL,
      'neighbor_if_name', '',
      'neighbor_if_index', NULL,
      'neighbor_device_id', g.device_uid,
      'neighbor_mgmt_addr', gd.ip,
      'neighbor_system_name', COALESCE(g.name, gd.name, gd.hostname, g.device_uid),
      'flow_pps', 0,
      'flow_bps', 0,
      'capacity_bps', 0,
      'flow_pps_ab', 0,
      'flow_pps_ba', 0,
      'flow_bps_ab', 0,
      'flow_bps_ba', 0,
      'telemetry_eligible', false,
      'telemetry_source', 'none',
      'telemetry_observed_at', COALESCE(g.observed_at, h.observed_at, g.updated_at, h.updated_at),
      'protocol', CONCAT(h.provider, '-inventory'),
      'confidence_tier', 'high',
      'confidence_reason', 'authoritative_virtualization_inventory',
      'evidence_class', 'hosted-virtual',
      'metadata', jsonb_build_object(
        'relation_type', 'HOSTED_ON',
        'source', CONCAT(h.provider, '-inventory'),
        'inference', 'authoritative_virtualization_inventory',
        'evidence_class', 'hosted-virtual',
        'topology_plane', 'hosted',
        'confidence_tier', 'high',
        'confidence_score', 95,
        'virtualization_provider', h.provider,
        'virtualization_host_provider_ref', h.provider_ref,
        'virtualization_guest_provider_ref', g.provider_ref,
        'virtualization_guest_type', g.guest_type,
        'virtualization_guest_vmid', g.vmid,
        'virtualization_status', g.status
      )
    ) AS row
    FROM platform.virtualization_guests g
    JOIN platform.virtualization_hosts h ON h.id = g.host_id
    LEFT JOIN platform.ocsf_devices hd ON hd.uid = h.device_uid
    LEFT JOIN platform.ocsf_devices gd ON gd.uid = g.device_uid
    WHERE h.device_uid IS NOT NULL
      AND g.device_uid IS NOT NULL
      AND btrim(h.device_uid) <> ''
      AND btrim(g.device_uid) <> ''
      AND h.device_uid <> g.device_uid
    ORDER BY COALESCE(g.observed_at, h.observed_at, g.updated_at, h.updated_at) DESC,
      h.device_uid ASC,
      g.device_uid ASC,
      h.provider ASC,
      h.provider_ref ASC,
      g.provider ASC,
      g.provider_ref ASC
    LIMIT $1
    """
  end

  @sobelow_skip ["SQL.Query"]
  defp fetch_virtualization_links_from_inventory do
    case Repo.query(virtualization_inventory_links_query(), [@max_virtualization_link_rows]) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        {:ok, Enum.map(rows, &first_column/1)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp first_column([value | _]), do: value
  defp first_column(value), do: value

  defp normalize_runtime_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(&normalize_runtime_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&canonical_runtime_row?/1)
    |> prioritize_runtime_rows()
  end

  @doc false
  @spec prioritize_runtime_rows([map()]) :: [map()]
  def prioritize_runtime_rows(rows) when is_list(rows) do
    {backbone_rows, attachment_rows} =
      Enum.split_with(rows, &backbone_runtime_row?/1)

    {inferred_segment_rows, ordinary_attachment_rows} =
      Enum.split_with(attachment_rows, &inferred_segment_runtime_row?/1)

    bounded_runtime_rows(backbone_rows, @max_backbone_link_rows) ++
      bounded_runtime_rows(inferred_segment_rows, @max_inferred_segment_link_rows) ++
      bounded_runtime_rows(ordinary_attachment_rows, @max_attachment_link_rows)
  end

  def prioritize_runtime_rows(_rows), do: []

  defp bounded_runtime_rows(rows, limit) when is_list(rows) and is_integer(limit) do
    rows
    |> Enum.sort_by(&canonical_runtime_row_key/1)
    |> Enum.take(limit)
  end

  defp canonical_runtime_row_key(row) when is_map(row) do
    {
      runtime_sort_text(map_fetch(row, :local_device_id)),
      runtime_sort_text(map_fetch(row, :neighbor_device_id)),
      runtime_relation_type(row),
      runtime_evidence_class(row),
      runtime_sort_ifindex(map_fetch(row, :local_if_index)),
      runtime_sort_text(map_fetch(row, :local_if_name)),
      runtime_sort_ifindex(map_fetch(row, :neighbor_if_index)),
      runtime_sort_text(map_fetch(row, :neighbor_if_name)),
      runtime_sort_text(map_fetch(row, :protocol)),
      :erlang.term_to_binary(row, [:deterministic])
    }
  end

  defp canonical_runtime_row_key(row), do: {"", "", "", "", -1, "", -1, "", "", inspect(row)}

  defp runtime_sort_text(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp runtime_sort_text(value) when is_atom(value), do: value |> Atom.to_string() |> runtime_sort_text()
  defp runtime_sort_text(_value), do: ""

  defp runtime_sort_ifindex(value) when is_integer(value), do: value

  defp runtime_sort_ifindex(value) when is_float(value), do: trunc(value)

  defp runtime_sort_ifindex(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp runtime_sort_ifindex(_value), do: -1

  @doc false
  @spec canonical_runtime_row?(map()) :: boolean()
  def canonical_runtime_row?(row) when is_map(row) do
    source = canonical_runtime_id(map_fetch(row, :local_device_id))
    target = canonical_runtime_id(map_fetch(row, :neighbor_device_id))

    is_binary(source) and is_binary(target) and source != target and
      (backbone_runtime_row?(row) or attachment_runtime_row?(row))
  end

  def canonical_runtime_row?(_row), do: false

  @doc false
  @spec backbone_runtime_row?(map()) :: boolean()
  def backbone_runtime_row?(row) when is_map(row) do
    relation_type = runtime_relation_type(row)
    evidence_class = runtime_evidence_class(row)

    relation_type in ["CONNECTS_TO", "LOGICAL_PEER", "HOSTED_ON"] or
      (relation_type == "" and evidence_class in ["direct", "direct-physical", "direct-logical", "hosted-virtual"])
  end

  def backbone_runtime_row?(_row), do: false

  @doc false
  @spec attachment_runtime_row?(map()) :: boolean()
  def attachment_runtime_row?(row) when is_map(row) do
    relation_type = runtime_relation_type(row)
    evidence_class = runtime_evidence_class(row)

    relation_type in ["ATTACHED_TO", "OBSERVED_TO"] or
      (relation_type == "" and evidence_class in ["endpoint-attachment", "observed-only"])
  end

  def attachment_runtime_row?(_row), do: false

  defp inferred_segment_runtime_row?(row) when is_map(row) do
    runtime_evidence_class(row) == "inferred-segment"
  end

  defp inferred_segment_runtime_row?(_row), do: false

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

  defp atomize_diagnostics(%{} = map) do
    Map.new(
      [
        :canonical_edges,
        :backbone_candidates,
        :attachment_candidates,
        :missing_relation_type,
        :missing_evidence_class,
        :missing_endpoint_ids,
        :non_canonical_endpoint_ids,
        :missing_observed_at
      ],
      fn key -> {key, parse_non_negative_int(map_fetch(map, key))} end
    )
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

  @doc false
  @spec decode_runtime_rows([map()]) :: [map()]
  def decode_runtime_rows(rows) when is_list(rows), do: Enum.map(rows, &decode_row/1)
  def decode_runtime_rows(_rows), do: []

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

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    Map.get(metadata, key) ||
      Enum.find_value(Map.keys(metadata), fn
        atom_key when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: Map.get(metadata, atom_key)

        _ ->
          nil
      end)
  end

  defp metadata_value(_metadata, _key), do: nil

  defp runtime_relation_type(row) when is_map(row) do
    row
    |> map_fetch(:metadata)
    |> metadata_value("relation_type")
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp runtime_evidence_class(row) when is_map(row) do
    row
    |> map_fetch(:evidence_class)
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp canonical_runtime_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.starts_with?(trimmed, "sr:") -> trimmed
      true -> nil
    end
  end

  defp canonical_runtime_id(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil

  defp parse_ifindex(value) when is_integer(value) and value >= 0, do: value

  defp parse_ifindex(value) when is_float(value) do
    rounded = trunc(Float.round(value))
    if rounded >= 0, do: rounded
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
