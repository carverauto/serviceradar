defmodule ServiceRadar.Observability.MtrGraph do
  @moduledoc """
  Projects MTR trace results into the Dgraph topology graph as MTR_PATH edges.

  Each trace creates a chain of edges connecting consecutive responding hops:

      (source:Device)-[MTR_PATH]->(hop1:HopNode)-[MTR_PATH]->(hop2:HopNode)->...->(target)

  Hop addresses that match known device IPs are linked to existing Device
  nodes. Unknown hops use HopNode vertices keyed by IP address. Each edge
  carries the far hop's latency, loss, jitter and hop numbers.

  Stale MTR_PATH edges are pruned after a configurable interval (default 24 hours).
  """

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.Repo

  require Logger

  @stale_hours 24

  @doc """
  Projects a list of MTR check results into the graph.

  Each result should have a "trace" key containing the full trace with "hops".
  """
  @spec project_traces(list(map()), map()) :: :ok
  def project_traces(results, status) when is_list(results) do
    agent_id = status[:agent_id] || "unknown"
    observed_at = DateTime.to_iso8601(DateTime.utc_now())

    # Collect all hop IPs across all traces for batch device lookup
    all_ips =
      results
      |> Enum.flat_map(fn result ->
        hops = get_in(result, ["trace", "hops"]) || []
        Enum.map(hops, fn hop -> hop["addr"] end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    ip_to_device = resolve_device_ips(all_ips)

    Enum.each(results, fn result ->
      trace = result["trace"] || %{}
      hops = trace["hops"] || []

      if length(hops) >= 2 do
        project_single_trace(hops, agent_id, observed_at, ip_to_device)
      end
    end)
  rescue
    e ->
      Logger.warning("MTR graph projection failed: #{inspect(e)}")
      :ok
  end

  def project_traces(_results, _status), do: :ok

  @doc """
  Removes MTR_PATH edges that haven't been observed within the stale window.
  """
  @spec prune_stale_edges(integer()) :: :ok
  def prune_stale_edges(stale_hours \\ @stale_hours) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.shift(hour: -stale_hours)
      |> DateTime.to_iso8601()

    DgraphPersist.prune_stale(cutoff, ["MTR_PATH"])
    Logger.debug("Pruned stale MTR_PATH edges older than #{stale_hours}h")
    :ok
  end

  defp project_single_trace(hops, agent_id, observed_at, ip_to_device) do
    responding_hops =
      hops
      |> Enum.filter(fn hop -> is_binary(hop["addr"]) and hop["addr"] != "" end)
      |> Enum.sort_by(fn hop -> hop["hop_number"] || 0 end)

    if length(responding_hops) < 2 do
      :ok
    else
      responding_hops
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [from_hop, to_hop] ->
        project_edge(from_hop, to_hop, agent_id, observed_at, ip_to_device)
      end)
    end
  end

  defp project_edge(from_hop, to_hop, agent_id, observed_at, ip_to_device) do
    {from_kind, from_id} = node_identity(from_hop, ip_to_device)
    {to_kind, to_id} = node_identity(to_hop, ip_to_device)

    DgraphPersist.upsert_mtr_path(%{
      from_id: from_id,
      to_id: to_id,
      from_kind: from_kind,
      to_kind: to_kind,
      agent_id: agent_id,
      observed_at: observed_at,
      mtr: path_metrics(from_hop, to_hop)
    })
  end

  # The far hop's measurements describe the segment that ends there.
  defp path_metrics(from_hop, to_hop) do
    %{
      avg_us: hop_int(to_hop, "avg_us", 0),
      loss_pct: hop_float(to_hop, "loss_pct", 0.0),
      jitter_us: hop_int(to_hop, "jitter_us", 0),
      from_hop: hop_int(from_hop, "hop_number", 0),
      to_hop: hop_int(to_hop, "hop_number", 0)
    }
  end

  defp hop_int(hop, key, default) when is_map(hop) do
    case hop[key] do
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      v when is_binary(v) -> parse_int(v, default)
      _ -> default
    end
  end

  defp hop_int(_hop, _key, default), do: default

  defp hop_float(hop, key, default) when is_map(hop) do
    case hop[key] do
      v when is_float(v) -> v
      v when is_integer(v) -> v / 1.0
      v when is_binary(v) -> parse_float(v, default)
      _ -> default
    end
  end

  defp hop_float(_hop, _key, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp parse_float(value, default) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_float(_value, default), do: default

  # A hop whose IP matches a known device is that Device; otherwise it is a
  # HopNode keyed by its address.
  defp node_identity(hop, ip_to_device) do
    addr = hop["addr"]

    case Map.get(ip_to_device, addr) do
      nil -> {:hop, addr}
      device_uid -> {:device, device_uid}
    end
  end

  # Batch-resolve hop IPs to device UIDs via inventory.
  # Returns a map of %{"10.0.0.1" => "device-uid-123", ...}
  defp resolve_device_ips([]), do: %{}

  defp resolve_device_ips(ips) do
    placeholders = Enum.map_join(1..length(ips), ", ", fn i -> "$#{i}" end)

    query = """
    SELECT ip, uid FROM platform.ocsf_devices
    WHERE ip IN (#{placeholders})
      AND ip IS NOT NULL
      AND deleted_at IS NULL
    """

    case Repo.query(query, ips) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [ip, uid] -> {ip, uid} end)

      {:error, reason} ->
        Logger.debug("Device IP lookup for MTR correlation failed: #{inspect(reason)}")
        %{}
    end
  end
end
