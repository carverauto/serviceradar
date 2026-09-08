defmodule ServiceRadar.Inventory.Sync.Interfaces do
  @moduledoc "Builds and bulk-upserts discovered interface records from sync updates."

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.Sync.Normalize

  require Logger

  def build_interface_upsert_records(resolved_updates, timestamp) do
    resolved_updates
    |> Enum.flat_map(fn {update, device_id} ->
      update.network_interfaces
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {interface, index} ->
        case build_interface_record(update, device_id, interface, index, timestamp) do
          nil -> []
          record -> [record]
        end
      end)
    end)
    |> log_sync_interface_shape()
  end

  defp build_interface_record(update, device_id, interface, index, timestamp)
       when is_map(interface) do
    interface_uid = interface_uid(interface, index)

    %{
      timestamp: timestamp,
      device_id: device_id,
      interface_uid: interface_uid,
      agent_id: update.agent_id,
      gateway_id: update.gateway_id,
      partition: update.partition || "default",
      device_ip: update.ip,
      if_name: interface_string(interface, ["name", :name]),
      if_descr: interface_string(interface, ["description", :description]),
      if_alias: interface_string(interface, ["alias", :alias]),
      if_phys_address: interface_string(interface, ["mac_address", :mac_address, "mac", :mac]),
      ip_addresses: interface_ip_addresses(interface),
      if_type_name: interface_string(interface, ["type", :type]),
      interface_kind: infer_interface_kind(interface),
      classifications: ["sync"],
      classification_meta: %{},
      classification_source: "sync",
      metadata: build_interface_metadata(interface),
      created_at: timestamp
    }
  end

  defp build_interface_record(_update, _device_id, _interface, _index, _timestamp), do: nil

  defp interface_uid(interface, index) do
    cond do
      (mac = interface_string(interface, ["mac_address", :mac_address, "mac", :mac])) not in [
        nil,
        ""
      ] ->
        "mac:#{String.downcase(mac)}"

      (name = interface_string(interface, ["name", :name])) not in [nil, ""] ->
        "name:#{name}"

      true ->
        "sync:#{index}"
    end
  end

  defp interface_ip_addresses(interface) do
    Enum.reject(
      [
        interface_string(interface, ["ipv4_address", :ipv4_address, "ip", :ip]),
        interface_string(interface, ["ipv6_address", :ipv6_address])
      ],
      &(&1 in [nil, ""])
    )
  end

  defp infer_interface_kind(interface) do
    type =
      interface
      |> interface_string(["type", :type])
      |> to_string()
      |> String.downcase()

    cond do
      type =~ "wireless" or type =~ "wifi" -> "wireless"
      type =~ "ethernet" or type =~ "wired" -> "physical"
      type in ["", "nil"] -> nil
      true -> type
    end
  end

  defp build_interface_metadata(interface) do
    %{}
    |> Normalize.maybe_put("source", "sync")
    |> Normalize.maybe_put("brand", interface_string(interface, ["brand", :brand]))
    |> Normalize.maybe_put(
      "broadcast_ssid",
      interface_string(interface, ["broadcast_ssid", :broadcast_ssid])
    )
    |> Normalize.maybe_put(
      "hidden_broadcast_ssid",
      interface_bool_string(interface, ["hidden_broadcast_ssid", :hidden_broadcast_ssid])
    )
    |> Normalize.maybe_put(
      "last_connected_ssid",
      interface_string(interface, ["last_connected_ssid", :last_connected_ssid])
    )
    |> Normalize.maybe_put("channels", interface_channels(interface))
    |> Normalize.maybe_put("vlan", interface_int_string(interface, ["vlan", :vlan]))
  end

  defp interface_string(map, keys), do: Normalize.map_get_string_any(map, keys)
  defp interface_int_string(map, keys), do: Normalize.map_get_int_string_any(map, keys)

  defp interface_bool_string(map, keys) do
    case Normalize.map_get_any(map, keys) do
      value when is_boolean(value) ->
        to_string(value)

      value when is_binary(value) ->
        if(String.trim(value) == "", do: nil, else: String.trim(value))

      _ ->
        nil
    end
  end

  defp interface_channels(interface) do
    case Normalize.map_get_any(interface, ["channels", :channels]) do
      channels when is_list(channels) -> Enum.map_join(channels, ",", &to_string/1)
      _ -> nil
    end
  end

  defp log_sync_interface_shape([]), do: []

  defp log_sync_interface_shape(records) do
    sample_keys =
      records
      |> List.first()
      |> Map.get(:metadata, %{})
      |> Map.keys()
      |> Enum.sort()

    Logger.info("SyncIngestor: prepared sync interface observations",
      interface_count: length(records),
      sample_metadata_keys: sample_keys
    )

    records
  end

  @doc false
  # The fields this writer may overwrite on conflict: exactly the ones
  # build_interface_record/5 sets, minus the identity columns and :created_at.
  #
  # Named rather than inline so the invariant is testable. A field listed here
  # that the builder does not set writes NULL over whatever the mapper wrote --
  # this writer never populates if_index, if_speed, speed_bps, if_admin_status,
  # if_oper_status, if_type, mtu, duplex or available_metrics, and copying the
  # mapper's list here would silently blank all nine on every sync run.
  @spec upsert_fields() :: [atom()]
  def upsert_fields do
    [
      :timestamp,
      :agent_id,
      :gateway_id,
      :partition,
      :device_ip,
      :if_name,
      :if_descr,
      :if_alias,
      :if_phys_address,
      :ip_addresses,
      :if_type_name,
      :interface_kind,
      :classifications,
      :classification_meta,
      :classification_source,
      :metadata
    ]
  end

  def bulk_upsert_interfaces(records) do
    case Ash.bulk_create(records, Interface, :create,
           actor: SystemActor.system(:sync_ingestor_interfaces),
           return_errors?: true,
           stop_on_error?: false,
           upsert?: true,
           upsert_identity: :unique_interface,
           # ONLY the fields build_interface_record/5 actually sets. See the
           # longer note at the mapper's writer: an empty list becomes
           # `DO UPDATE SET <key> = EXCLUDED.<key>` once :timestamp leaves the
           # identity, and a list copied from the mapper would blank the
           # operational columns this writer never populates -- if_index,
           # if_speed, speed_bps, if_admin_status, if_oper_status, if_type, mtu,
           # duplex, available_metrics.
           upsert_fields: upsert_fields()
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: []} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        Logger.warning("Bulk sync interface upsert partially failed: #{inspect(errors)}")
        {:error, errors}

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("Bulk sync interface upsert failed: #{inspect(errors)}")
        {:error, errors}
    end
  rescue
    e ->
      Logger.warning("Bulk sync interface upsert failed: #{inspect(e)}")
      {:error, e}
  end
end
