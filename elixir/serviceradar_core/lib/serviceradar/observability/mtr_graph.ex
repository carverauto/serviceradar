defmodule ServiceRadar.Observability.MtrGraph do
  @moduledoc """
  Projects MTR trace results into the Apache AGE platform_graph as MTR_PATH edges.

  Each trace creates a chain of edges connecting consecutive responding hops:

      (source:Device)-[:MTR_PATH]->(hop1:MtrHop)-[:MTR_PATH]->(hop2:MtrHop)->...->(target)

  Hop nodes that match known device IPs are linked to existing Device nodes.
  Unknown hops use MtrHop nodes keyed by IP address.

  Stale MTR_PATH edges are pruned after a configurable interval (default 24 hours).
  """

  alias ServiceRadar.Graph
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
      |> DateTime.add(-stale_hours * 3600, :second)
      |> DateTime.to_iso8601()

    cypher = """
    MATCH ()-[r:MTR_PATH]->()
    WHERE r.last_observed_at < '#{Graph.escape(cutoff)}'
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok ->
        Logger.debug("Pruned stale MTR_PATH edges older than #{stale_hours}h")

      {:error, reason} ->
        Logger.warning("Failed to prune stale MTR_PATH edges: #{inspect(reason)}")
    end

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
    {from_label, from_id} = node_identity(from_hop, ip_to_device)
    {to_label, to_id} = node_identity(to_hop, ip_to_device)

    cypher =
      edge_upsert_cypher(
        from_hop,
        to_hop,
        from_label,
        from_id,
        to_label,
        to_id,
        agent_id,
        observed_at
      )

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("MTR graph edge upsert failed: #{inspect(reason)}")
    end
  end

  defp edge_upsert_cypher(
         from_hop,
         to_hop,
         from_label,
         from_id,
         to_label,
         to_id,
         agent_id,
         observed_at
       ) do
    from_asn = hop_asn(from_hop)
    to_asn = hop_asn(to_hop)
    from_hop_no = hop_int(from_hop, "hop_number", 0)
    to_hop_no = hop_int(to_hop, "hop_number", 0)
    avg_us = hop_int(to_hop, "avg_us", 0)
    loss_pct = hop_float(to_hop, "loss_pct", 0.0)
    jitter_us = hop_int(to_hop, "jitter_us", 0)

    """
    MERGE (a:#{from_label} {id: '#{Graph.escape(from_id)}'})
    #{set_node_props(from_label, "a", from_hop, from_asn)}
    MERGE (b:#{to_label} {id: '#{Graph.escape(to_id)}'})
    #{set_node_props(to_label, "b", to_hop, to_asn)}
    MERGE (a)-[r:MTR_PATH]->(b)
    SET r.first_observed_at = coalesce(r.first_observed_at, '#{Graph.escape(observed_at)}')
    SET r.last_observed_at = '#{Graph.escape(observed_at)}'
    SET r.ingestor = 'mtr_v1'
    SET r.agent_id = '#{Graph.escape(agent_id)}'
    SET r.from_hop = #{from_hop_no}
    SET r.to_hop = #{to_hop_no}
    SET r.avg_us = #{avg_us}
    SET r.loss_pct = #{loss_pct}
    SET r.jitter_us = #{jitter_us}
    """
  end

  defp set_node_props("MtrHop", var, hop, asn) do
    """
    SET #{var}.addr = '#{Graph.escape(hop["addr"])}'
    #{set_prop(var, "hostname", hop["hostname"])}
    #{set_prop(var, "asn", asn["asn"])}
    #{set_prop(var, "asn_org", asn["org"])}
    """
  end

  defp set_node_props(_label, _var, _hop, _asn), do: ""

  defp hop_asn(hop) when is_map(hop), do: hop["asn"] || %{}
  defp hop_asn(_), do: %{}

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

  # If the hop IP matches a known device, use Device label with device UID.
  # Otherwise fall back to MtrHop label keyed by IP.
  defp node_identity(hop, ip_to_device) do
    addr = hop["addr"]

    case Map.get(ip_to_device, addr) do
      nil -> {"MtrHop", "mtr:#{addr || "unknown"}"}
      device_uid -> {"Device", device_uid}
    end
  end

  # Batch-resolve hop IPs to device UIDs via the devices table.
  # Returns a map of %{"10.0.0.1" => "device-uid-123", ...}
  defp resolve_device_ips([]), do: %{}

  defp resolve_device_ips(ips) do
    placeholders = Enum.map_join(1..length(ips), ", ", fn i -> "$#{i}" end)

    query = """
    SELECT ip, uid FROM devices
    WHERE ip IN (#{placeholders})
      AND ip IS NOT NULL
    """

    case Repo.query(query, ips) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [ip, uid] -> {ip, uid} end)

      {:error, reason} ->
        Logger.debug("Device IP lookup for MTR correlation failed: #{inspect(reason)}")
        %{}
    end
  end

  defp set_prop(_var, _prop, nil), do: ""
  defp set_prop(_var, _prop, ""), do: ""
  defp set_prop(_var, _prop, 0), do: ""

  defp set_prop(var, prop, value) when is_integer(value) do
    "SET #{var}.#{prop} = #{value}"
  end

  defp set_prop(var, prop, value) when is_float(value) do
    "SET #{var}.#{prop} = #{value}"
  end

  defp set_prop(var, prop, value) do
    "SET #{var}.#{prop} = '#{Graph.escape(value)}'"
  end
end
