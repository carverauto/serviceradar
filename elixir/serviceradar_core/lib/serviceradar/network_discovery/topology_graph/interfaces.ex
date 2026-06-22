defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Interfaces do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  @spec upsert_interfaces([map()]) :: :ok
  def upsert_interfaces([]), do: :ok

  def upsert_interfaces(interfaces) when is_list(interfaces) do
    Enum.each(interfaces, &upsert_interface/1)
    :ok
  end

  @spec upsert_managed_by(String.t(), String.t()) :: :ok
  def upsert_managed_by(device_uid, management_device_uid)
      when is_binary(device_uid) and is_binary(management_device_uid) do
    device_uid = Utils.non_blank(device_uid)
    management_device_uid = Utils.non_blank(management_device_uid)

    if is_nil(device_uid) or is_nil(management_device_uid) do
      :ok
    else
      cypher = """
      MERGE (child:Device {id: '#{Graph.escape(device_uid)}'})
      MERGE (mgmt:Device {id: '#{Graph.escape(management_device_uid)}'})
      MERGE (child)-[r:MANAGED_BY]->(mgmt)
      SET r.source = 'mapper'
      MERGE (mgmt)-[rev:MANAGES]->(child)
      SET rev.source = 'mapper'
      """

      case Graph.execute(cypher) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("MANAGED_BY graph upsert failed: #{inspect(reason)}")
      end
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
    device_id = Utils.non_blank(Utils.link_value(interface, :device_id))
    if_name = Utils.link_value(interface, :if_name)
    if_index = Utils.link_value(interface, :if_index)
    interface_id = Utils.interface_id(device_id, if_name, if_index)

    if is_nil(device_id) or is_nil(interface_id) do
      {:error, :missing_ids}
    else
      {:ok,
       %{
         device_id: device_id,
         interface_id: interface_id,
         if_name: if_name,
         if_index: if_index,
         if_descr: Utils.link_value(interface, :if_descr),
         if_alias: Utils.link_value(interface, :if_alias),
         if_phys_address: Utils.link_value(interface, :if_phys_address),
         ip_addresses: Utils.link_value(interface, :ip_addresses)
       }}
    end
  end

  defp upsert_interface_payload(payload) do
    cypher = """
    MERGE (d:Device {id: '#{Graph.escape(payload.device_id)}'})
    MERGE (i:Interface {id: '#{Graph.escape(payload.interface_id)}'})
    SET i.device_id = '#{Graph.escape(payload.device_id)}'
    #{Utils.set_prop("i", "name", payload.if_name)}
    #{Utils.set_prop("i", "ifindex", payload.if_index)}
    #{Utils.set_prop("i", "descr", payload.if_descr)}
    #{Utils.set_prop("i", "alias", payload.if_alias)}
    #{Utils.set_prop("i", "mac", payload.if_phys_address)}
    #{Utils.set_prop("i", "ip_addresses", payload.ip_addresses)}
    MERGE (d)-[r:HAS_INTERFACE]->(i)
    SET r.source = 'mapper'
    """

    case Graph.execute(cypher) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Interface graph upsert failed: #{inspect(reason)}")
    end
  end
end
