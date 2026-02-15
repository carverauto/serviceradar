defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  require Logger

  alias ServiceRadar.Graph
  @default_stale_minutes 180
  @eligible_confidence_tiers MapSet.new(["high", "medium"])

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    links = authoritative_links(links)

    {local_device_ids, neighbor_index, projected_count, skipped_low_count} =
      Enum.reduce(links, {MapSet.new(), %{}, 0, 0}, &reduce_topology_link/2)

    prune_unseen_projected_links(neighbor_index)
    prune_stale_projected_links(MapSet.to_list(local_device_ids))

    if skipped_low_count > 0 do
      Logger.debug(
        "Skipped #{skipped_low_count} low-confidence topology link(s); projected #{projected_count} link(s)"
      )
    end

    :ok
  end

  # Prefer direct topology evidence (LLDP/CDP). If none exists for a local node,
  # project only one inferred parent edge for that local to avoid multi-parent drift.
  defp authoritative_links(links) do
    links
    |> Enum.group_by(&non_blank(link_value(&1, :local_device_id)))
    |> Enum.flat_map(fn
      {nil, _group} ->
        []

      {_local, group} ->
        direct =
          Enum.filter(group, fn link ->
            protocol = normalize_protocol(link_value(link, :protocol))
            protocol in ["lldp", "cdp"]
          end)

        if direct != [] do
          direct
        else
          inferred =
            Enum.filter(group, fn link ->
              protocol = normalize_protocol(link_value(link, :protocol))
              protocol in ["snmp-parent", "snmp-site", "l3-uplink", "inferred"]
            end)

          fallback_candidates = if inferred == [], do: group, else: inferred

          case best_inferred_link(fallback_candidates) do
            nil -> []
            best -> [best]
          end
        end
    end)
  end

  defp best_inferred_link([]), do: nil

  defp best_inferred_link(links) do
    Enum.max_by(links, fn link ->
      protocol_rank =
        case normalize_protocol(link_value(link, :protocol)) do
          "snmp-parent" -> 40
          "snmp-site" -> 30
          "l3-uplink" -> 20
          "inferred" -> 10
          _ -> 0
        end

      confidence =
        confidence_score(link, link_value(link, :metadata) || %{})
        |> normalize_positive_int(0)

      observed_rank =
        case link_value(link, :timestamp) do
          %DateTime{} = dt -> DateTime.to_unix(dt)
          _ -> 0
        end

      {protocol_rank, confidence, observed_rank}
    end)
  end

  defp reduce_topology_link(link, {local_ids, neighbor_index, projected, skipped_low}) do
    case build_link_payload(link) do
      {:ok, payload} ->
        local_ids = MapSet.put(local_ids, payload.local_device_id)

        if projectable_confidence_tier?(payload.confidence_tier) do
          upsert_link_payload(payload)

          neighbor_index =
            add_neighbor_edge(neighbor_index, payload.local_device_id, payload.neighbor_device_id)

          {local_ids, neighbor_index, projected + 1, skipped_low}
        else
          {local_ids, neighbor_index, projected, skipped_low + 1}
        end

      {:error, :missing_ids} ->
        Logger.debug("Skipping topology link missing device identifiers")
        {local_ids, neighbor_index, projected, skipped_low}
    end
  end

  defp add_neighbor_edge(index, local_device_id, neighbor_device_id) do
    update_in(index, [local_device_id], fn
      nil -> MapSet.new([neighbor_device_id])
      existing -> MapSet.put(existing, neighbor_device_id)
    end)
  end

  @spec upsert_interfaces([map()]) :: :ok
  def upsert_interfaces([]), do: :ok

  def upsert_interfaces(interfaces) when is_list(interfaces) do
    Enum.each(interfaces, &upsert_interface/1)
    :ok
  end

  @doc """
  Creates a MANAGED_BY edge from a device to its management device.
  """
  @spec upsert_managed_by(String.t(), String.t()) :: :ok
  def upsert_managed_by(device_uid, management_device_uid)
      when is_binary(device_uid) and is_binary(management_device_uid) do
    cypher = """
    MERGE (child:Device {id: '#{Graph.escape(device_uid)}'})
    MERGE (mgmt:Device {id: '#{Graph.escape(management_device_uid)}'})
    MERGE (child)-[r:MANAGED_BY]->(mgmt)
    SET r.source = 'mapper'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("MANAGED_BY graph upsert failed: #{inspect(reason)}")
    end
  end

  defp upsert_interface(interface) when is_map(interface) do
    case build_interface_payload(interface) do
      {:ok, payload} ->
        upsert_interface_payload(payload)

      {:error, :missing_ids} ->
        Logger.debug("Skipping interface graph upsert missing identifiers")
        :ok
    end
  end

  defp upsert_interface(_interface), do: :ok

  defp build_interface_payload(interface) do
    device_id = non_blank(link_value(interface, :device_id))
    if_name = link_value(interface, :if_name)
    if_index = link_value(interface, :if_index)
    interface_id = interface_id(device_id, if_name, if_index)

    if is_nil(device_id) or is_nil(interface_id) do
      {:error, :missing_ids}
    else
      {:ok,
       %{
         device_id: device_id,
         interface_id: interface_id,
         if_name: if_name,
         if_index: if_index,
         if_descr: link_value(interface, :if_descr),
         if_alias: link_value(interface, :if_alias),
         if_phys_address: link_value(interface, :if_phys_address),
         ip_addresses: link_value(interface, :ip_addresses)
       }}
    end
  end

  defp build_link_payload(link) do
    local_device_id = non_blank(link_value(link, :local_device_id))
    neighbor_device_id = neighbor_device_id(link)
    local_interface_id = local_interface_id(link, local_device_id)
    neighbor_port = neighbor_port(link)
    neighbor_interface_id = neighbor_interface_id(neighbor_device_id, neighbor_port)
    metadata = link_value(link, :metadata) || %{}
    confidence_tier = confidence_tier(link, metadata)
    confidence_score = confidence_score(link, metadata)
    confidence_reason = confidence_reason(link, metadata)
    observed_at = observed_at(link)

    if is_nil(local_device_id) or is_nil(neighbor_device_id) do
      {:error, :missing_ids}
    else
      {:ok,
       %{
         local_device_id: local_device_id,
         neighbor_device_id: neighbor_device_id,
         local_interface_id: local_interface_id,
         neighbor_interface_id: neighbor_interface_id,
         protocol: link_value(link, :protocol) || "unknown",
         local_if_name: link_value(link, :local_if_name),
         local_if_index: link_value(link, :local_if_index),
         neighbor_port_name: neighbor_port,
         neighbor_name: link_value(link, :neighbor_system_name),
         neighbor_ip: link_value(link, :neighbor_mgmt_addr),
         confidence_tier: confidence_tier,
         confidence_score: confidence_score,
         confidence_reason: confidence_reason,
         observed_at: observed_at
       }}
    end
  end

  defp local_interface_id(link, local_device_id) do
    interface_id(
      local_device_id,
      link_value(link, :local_if_name),
      link_value(link, :local_if_index)
    ) || default_interface_id(local_device_id, "unknown-local")
  end

  defp neighbor_port(link) do
    Enum.find_value(
      [
        :neighbor_port_id,
        :neighbor_port_descr,
        :neighbor_chassis_id,
        :neighbor_system_name,
        :neighbor_mgmt_addr
      ],
      fn key -> non_blank(link_value(link, key)) end
    )
  end

  defp neighbor_interface_id(neighbor_device_id, neighbor_port) do
    interface_id(neighbor_device_id, neighbor_port, nil) ||
      default_interface_id(neighbor_device_id, "unknown-neighbor")
  end

  defp upsert_interface_payload(payload) do
    cypher = """
    MERGE (d:Device {id: '#{Graph.escape(payload.device_id)}'})
    MERGE (i:Interface {id: '#{Graph.escape(payload.interface_id)}'})
    SET i.device_id = '#{Graph.escape(payload.device_id)}'
    #{set_prop("i", "name", payload.if_name)}
    #{set_prop("i", "ifindex", payload.if_index)}
    #{set_prop("i", "descr", payload.if_descr)}
    #{set_prop("i", "alias", payload.if_alias)}
    #{set_prop("i", "mac", payload.if_phys_address)}
    #{set_prop("i", "ip_addresses", payload.ip_addresses)}
    MERGE (d)-[r:HAS_INTERFACE]->(i)
    SET r.source = 'mapper'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Interface graph upsert failed: #{inspect(reason)}")
    end
  end

  defp upsert_link_payload(payload) do
    cypher = """
    MERGE (a:Device {id: '#{Graph.escape(payload.local_device_id)}'})
    MERGE (b:Device {id: '#{Graph.escape(payload.neighbor_device_id)}'})
    #{set_prop("b", "name", payload.neighbor_name)}
    #{set_prop("b", "ip", payload.neighbor_ip)}
    MERGE (ai:Interface {id: '#{Graph.escape(payload.local_interface_id)}'})
    SET ai.device_id = '#{Graph.escape(payload.local_device_id)}'
    #{set_prop("ai", "name", payload.local_if_name)}
    #{set_prop("ai", "ifindex", payload.local_if_index)}
    MERGE (bi:Interface {id: '#{Graph.escape(payload.neighbor_interface_id)}'})
    SET bi.device_id = '#{Graph.escape(payload.neighbor_device_id)}'
    #{set_prop("bi", "name", payload.neighbor_port_name)}
    MERGE (a)-[r1:HAS_INTERFACE]->(ai)
    SET r1.source = 'mapper'
    MERGE (b)-[r2:HAS_INTERFACE]->(bi)
    SET r2.source = 'mapper'
    MERGE (ai)-[r:CONNECTS_TO]->(bi)
    SET r.first_observed_at = coalesce(r.first_observed_at, '#{Graph.escape(payload.observed_at)}')
    SET r.ingestor = 'mapper_topology_v1'
    SET r.source = '#{Graph.escape(payload.protocol)}'
    SET r.protocol = '#{Graph.escape(payload.protocol)}'
    SET r.confidence_tier = '#{Graph.escape(payload.confidence_tier)}'
    SET r.confidence_score = #{payload.confidence_score}
    SET r.confidence_reason = '#{Graph.escape(payload.confidence_reason)}'
    SET r.observed_at = '#{Graph.escape(payload.observed_at)}'
    SET r.last_observed_at = '#{Graph.escape(payload.observed_at)}'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
    end
  end

  defp neighbor_device_id(link) do
    link_value(link, :neighbor_device_id) ||
      link_value(link, :neighbor_mgmt_addr) ||
      link_value(link, :neighbor_chassis_id) ||
      link_value(link, :neighbor_system_name)
  end

  defp projectable_confidence_tier?(tier) do
    MapSet.member?(@eligible_confidence_tiers, normalize_confidence_tier(tier))
  end

  defp confidence_tier(link, metadata) do
    link_value(link, :confidence_tier) ||
      map_value(metadata, :confidence_tier) ||
      "low"
  end

  defp confidence_score(link, metadata) do
    link_value(link, :confidence_score)
    |> parse_confidence_score()
    |> case do
      nil ->
        metadata
        |> map_value(:confidence_score)
        |> parse_confidence_score()
        |> Kernel.||(0)

      score ->
        score
    end
  end

  defp confidence_reason(link, metadata) do
    link_value(link, :confidence_reason) ||
      map_value(metadata, :confidence_reason) ||
      "unspecified"
  end

  defp observed_at(link) do
    case link_value(link, :timestamp) do
      %DateTime{} = dt ->
        dt
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      value when is_binary(value) ->
        value

      _ ->
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
    end
  end

  defp prune_unseen_projected_links(neighbor_index) when map_size(neighbor_index) == 0, do: :ok

  defp prune_unseen_projected_links(neighbor_index) do
    Enum.each(neighbor_index, fn {local_device_id, neighbor_ids} ->
      escaped_local = Graph.escape(local_device_id)

      allowed_neighbors =
        neighbor_ids
        |> MapSet.to_list()
        |> Enum.map_join(", ", &"'#{Graph.escape(&1)}'")

      cypher = """
      MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)
      WHERE a.device_id = '#{escaped_local}'
        AND r.ingestor = 'mapper_topology_v1'
        AND (b.device_id IS NULL OR NOT b.device_id IN [#{allowed_neighbors}])
      DELETE r
      """

      case Graph.execute(cypher) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Topology unseen edge pruning failed: #{inspect(reason)}")
      end
    end)
  end

  defp prune_stale_projected_links([]), do: :ok

  defp prune_stale_projected_links(local_device_ids) do
    stale_cutoff = stale_cutoff_iso8601()
    escaped_ids = Enum.map_join(local_device_ids, ", ", &"'#{Graph.escape(&1)}'")

    cypher = """
    MATCH (a:Interface)-[r:CONNECTS_TO]->(:Interface)
    WHERE a.device_id IN [#{escaped_ids}]
      AND r.ingestor = 'mapper_topology_v1'
      AND r.last_observed_at IS NOT NULL
      AND r.last_observed_at < '#{Graph.escape(stale_cutoff)}'
    DELETE r
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Topology stale edge pruning failed: #{inspect(reason)}")
    end
  end

  defp stale_cutoff_iso8601 do
    stale_minutes =
      Application.get_env(
        :serviceradar_core,
        :mapper_topology_edge_stale_minutes,
        @default_stale_minutes
      )
      |> normalize_positive_int(@default_stale_minutes)

    DateTime.utc_now()
    |> DateTime.add(-stale_minutes * 60, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp parse_confidence_score(value) when is_integer(value), do: value

  defp parse_confidence_score(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_confidence_score(_value), do: nil

  defp normalize_protocol(nil), do: "unknown"

  defp normalize_protocol(protocol) do
    protocol
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_confidence_tier(nil), do: "low"

  defp normalize_confidence_tier(tier) do
    tier
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp link_value(link, key) do
    Map.get(link, key) || Map.get(link, to_string(key))
  end

  defp interface_id(nil, _if_name, _if_index), do: nil

  defp interface_id(device_id, if_name, if_index) do
    cond do
      is_binary(if_name) and String.trim(if_name) != "" ->
        "#{device_id}/#{String.trim(if_name)}"

      is_integer(if_index) ->
        "#{device_id}/ifindex:#{if_index}"

      true ->
        nil
    end
  end

  defp default_interface_id(nil, _label), do: nil
  defp default_interface_id(device_id, label), do: "#{device_id}/#{label}"

  defp non_blank(nil), do: nil

  defp non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.downcase(trimmed) in ["nil", "null", "undefined"] -> nil
      true -> trimmed
    end
  end

  defp non_blank(value) when is_atom(value) do
    if value in [nil, :null, :undefined], do: nil, else: Atom.to_string(value)
  end

  defp non_blank(value), do: value |> to_string() |> non_blank()

  defp set_prop(_node, _field, nil), do: ""
  defp set_prop(_node, _field, ""), do: ""

  defp set_prop(node, field, value) when is_list(value) do
    list = Enum.map_join(value, ", ", &cypher_value/1)
    "SET #{node}.#{field} = [#{list}]"
  end

  defp set_prop(node, field, value) do
    "SET #{node}.#{field} = #{cypher_value(value)}"
  end

  defp cypher_value(value) when is_integer(value), do: Integer.to_string(value)
  defp cypher_value(value) when is_float(value), do: Float.to_string(value)
  defp cypher_value(value) when is_binary(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(value) when is_atom(value), do: "'#{Graph.escape(value)}'"
  defp cypher_value(_value), do: "null"
end
