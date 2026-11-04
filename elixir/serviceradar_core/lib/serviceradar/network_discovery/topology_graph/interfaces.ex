defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Interfaces do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  require Logger

  @spec upsert_interfaces([map()]) :: :ok | {:error, term()}
  def upsert_interfaces([]), do: :ok

  def upsert_interfaces(interfaces) when is_list(interfaces) do
    interfaces
    |> Enum.flat_map(&interface_payload/1)
    |> DgraphPersist.upsert_interfaces()
  end

  @spec upsert_managed_by(String.t(), String.t()) :: :ok
  def upsert_managed_by(device_uid, management_device_uid)
      when is_binary(device_uid) and is_binary(management_device_uid) do
    device_uid = Utils.non_blank(device_uid)
    management_device_uid = Utils.non_blank(management_device_uid)

    if is_nil(device_uid) or is_nil(management_device_uid) do
      :ok
    else
      DgraphPersist.upsert_managed_by(device_uid, management_device_uid)
    end
  end

  defp interface_payload(interface) when is_map(interface) do
    case build_interface_payload(interface) do
      {:ok, payload} ->
        [payload]

      {:error, :missing_ids} ->
        Logger.debug("Skipping interface graph upsert missing identifiers")
        []
    end
  end

  defp interface_payload(_interface), do: []

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
end
