defmodule ServiceRadar.Inventory.Identity.ResolveByAddress do
  @moduledoc """
  Resolves a live inventory device from IP + partition, with optional MAC
  corroboration. Used by NCO validation runs.

  IP is authoritative. A MAC that is missing from inventory is ignored; a MAC
  that points at a different live device than the IP is a conflict. This
  never mints a uid.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Mac

  @default_partition "default"

  @type uid :: String.t()
  @type error ::
          :not_found
          | :invalid_ip
          | {:ambiguous, [uid()]}
          | {:mac_ip_conflict, uid(), uid()}

  @spec resolve(map() | keyword()) :: {:ok, uid()} | {:error, error()}
  def resolve(opts) when is_list(opts), do: resolve(Map.new(opts))

  def resolve(%{} = opts) do
    actor = Map.get(opts, :actor) || SystemActor.system(:resolve_by_address)
    partition = Map.get(opts, :partition) || Map.get(opts, "partition") || @default_partition

    partition =
      if is_binary(partition) and partition != "", do: partition, else: @default_partition

    with {:ok, ip} <- normalize_ip(opts),
         {:ok, ip_uid} <- resolve_ip(ip, partition, actor),
         :ok <- corroborate_mac(opts, partition, ip_uid, actor) do
      {:ok, ip_uid}
    end
  end

  defp normalize_ip(opts) do
    raw = opts[:ip] || opts["ip"]

    if is_binary(raw) do
      ip = String.trim(raw)

      case :inet.parse_strict_address(String.to_charlist(ip)) do
        {:ok, _} -> {:ok, ip}
        _ -> {:error, :invalid_ip}
      end
    else
      {:error, :invalid_ip}
    end
  end

  defp resolve_ip(ip, partition, actor) do
    case identifier_uids(:ip, ip, partition, actor) do
      [uid] ->
        if live_device?(uid, actor), do: {:ok, uid}, else: fallback_device_ip(ip, actor)

      [] ->
        fallback_device_ip(ip, actor)

      uids ->
        {:error, {:ambiguous, Enum.sort(uids)}}
    end
  end

  defp fallback_device_ip(ip, actor) do
    query = Ash.Query.for_read(Device, :by_ip, %{ip: ip, include_deleted: false}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, [%{uid: uid}]} -> {:ok, uid}
      {:ok, []} -> {:error, :not_found}
      {:ok, devices} -> {:error, {:ambiguous, devices |> Enum.map(& &1.uid) |> Enum.sort()}}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp corroborate_mac(opts, partition, ip_uid, actor) do
    raw = opts[:mac] || opts["mac"]

    case Mac.normalize_mac(raw) do
      nil ->
        :ok

      mac ->
        case mac_uids(mac, partition, actor) do
          [] ->
            :ok

          uids ->
            if ip_uid in uids do
              :ok
            else
              {:error, {:mac_ip_conflict, ip_uid, hd(uids)}}
            end
        end
    end
  end

  defp mac_uids(mac, partition, actor) do
    from_ids = identifier_uids(:mac, mac, partition, actor)
    from_row = device_mac_uids(mac, actor)
    Enum.uniq(from_ids ++ from_row)
  end

  defp device_mac_uids(mac, actor) do
    colon = format_colon_mac(mac)

    query =
      Ash.Query.for_read(Device, :by_mac, %{mac: colon, include_deleted: false}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, devices} -> Enum.map(devices, & &1.uid)
      {:error, _} -> []
    end
  end

  defp format_colon_mac(mac) when byte_size(mac) == 12 do
    mac
    |> String.codepoints()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  defp format_colon_mac(mac), do: mac

  defp identifier_uids(type, value, partition, actor) do
    query =
      Ash.Query.for_read(
        DeviceIdentifier,
        :lookup,
        %{identifier_type: type, identifier_value: value, partition: partition},
        actor: actor
      )

    case Ash.read(query, actor: actor) do
      {:ok, rows} ->
        rows
        |> Enum.map(& &1.device_id)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp live_device?(uid, actor) do
    case Device.get_by_uid(uid, false, actor: actor) do
      {:ok, %{deleted_at: nil}} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  end
end
