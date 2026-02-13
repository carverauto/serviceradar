defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  require Logger

  alias ServiceRadar.Graph

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    Enum.each(links, &upsert_link/1)
    :ok
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

  defp upsert_link(link) when is_map(link) do
    case build_link_payload(link) do
      {:ok, payload} ->
        upsert_link_payload(payload)

      {:error, :missing_ids} ->
        Logger.debug("Skipping topology link missing device identifiers")
        :ok
    end
  end

  defp upsert_link(_link), do: :ok

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
    device_id = link_value(interface, :device_id)
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
    local_device_id = link_value(link, :local_device_id)
    neighbor_device_id = neighbor_device_id(link)
    local_interface_id = local_interface_id(link, local_device_id)
    neighbor_port = neighbor_port(link)
    neighbor_interface_id = neighbor_interface_id(neighbor_device_id, neighbor_port)

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
         neighbor_ip: link_value(link, :neighbor_mgmt_addr)
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
    SET r.source = '#{Graph.escape(payload.protocol)}'
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
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(value), do: value

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
