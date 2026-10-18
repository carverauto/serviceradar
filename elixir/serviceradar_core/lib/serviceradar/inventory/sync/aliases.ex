defmodule ServiceRadar.Inventory.Sync.Aliases do
  @moduledoc """
  IP alias sightings and alias-conflict merges for sync batches.
  An alias holder that owns an identifier of its own is never merged on the
  shared address (a recycled DHCP address is not evidence of sameness); its
  alias is invalidated instead. Other merges route through IdentityReconciler
  and inherit its stability guards (distinct-agent veto invalidates the alias;
  cooldown blocks oscillation).

  It also keeps the address a declarative source displaces (`held_addresses/2`,
  `replaced_addresses/2`, `retain_replaced_addresses/2`).
  """

  import Ecto.Query

  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Repo

  require Logger

  @replaced_address_source "replaced_primary_address"

  @doc """
  The primary addresses the batch's declarative updates may replace, keyed by device uid.

  A device's record is built from the batch's last update for its uid (`DeviceRecords`), so
  that update's source decides: a declarative update that wins keeps the address it replaces
  even after an observed sighting of the device earlier in the batch, and an observed update
  that wins keeps nothing.

  A declarative source (`SourcePolicy.observed_address_source?/1` is false: a hypervisor API,
  NetBox, AWX, a generic integration) reports the address it is configured with, which is
  not evidence that the address the device currently holds is gone. A hypervisor node, for
  one, is reported at its cluster address while discovery reached it on its management
  address. The upsert still takes the configured address (`DeviceWrites`), so the held one
  is read here, under the batch's row locks, and kept as an alias in the same transaction.

  An observed source is left out on purpose: it saw the device at the new address, so the old
  one is the stale side of a move (DHCP churn), and keeping it would attribute the next
  holder of that address to this device.
  """
  @spec held_addresses([map()], [{map(), String.t()}]) :: %{String.t() => map()}
  def held_addresses(device_records, resolved_updates) do
    winning_updates = Map.new(resolved_updates, fn {update, uid} -> {uid, update} end)

    uids =
      for record <- device_records,
          declarative_write?(Map.get(winning_updates, record.uid)),
          present_ip?(Map.get(record, :ip)),
          uniq: true,
          do: record.uid

    if uids == [] do
      %{}
    else
      from(d in Device,
        where: d.uid in ^uids and is_nil(d.deleted_at) and not is_nil(d.ip),
        select: {d.uid, d.ip, d.partition}
      )
      |> Repo.all()
      |> Enum.filter(fn {_uid, ip, _partition} -> AliasPolicy.valid_alias_ip?(ip) end)
      |> Map.new(fn {uid, ip, partition} -> {uid, %{ip: ip, partition: partition}} end)
    end
  end

  defp declarative_write?(nil), do: false
  defp declarative_write?(update), do: not SourcePolicy.observed_address_source?(update)

  @doc """
  The held addresses (`held_addresses/2`) the write replaced: the device is still live under
  its own uid (not redirected by `remap`), holds a different address now, and no other live
  device of its partition holds the old one (an address that moved to another device is that
  device's, not an alias of this one). Read under the batch's row locks, after the upsert.
  """
  @spec replaced_addresses(%{String.t() => map()}, %{String.t() => String.t()}) :: [map()]
  def replaced_addresses(held, _remap) when map_size(held) == 0, do: []

  def replaced_addresses(held, remap) do
    uids = held |> Map.keys() |> Enum.reject(&Map.has_key?(remap, &1))

    current =
      from(d in Device,
        where: d.uid in ^uids and is_nil(d.deleted_at),
        select: {d.uid, d.ip}
      )
      |> Repo.all()
      |> Map.new()

    candidates =
      Enum.flat_map(uids, fn uid ->
        %{ip: old_ip} = held_address = Map.fetch!(held, uid)
        new_ip = Map.get(current, uid)

        if present_ip?(new_ip) and new_ip != old_ip,
          do: [Map.merge(held_address, %{device_id: uid, replaced_by: new_ip})],
          else: []
      end)

    held_elsewhere = live_holders(Enum.map(candidates, & &1.ip))

    Enum.reject(candidates, &MapSet.member?(held_elsewhere, {&1.partition, &1.ip}))
  end

  @doc """
  Records each replaced address (`replaced_addresses/2`) as a `:detected` IP alias of its
  device, so the address still resolves to the device and a sweep that reaches it confirms the
  alias (`SweepResultsIngestor`). A device that already has a row for the address keeps it as it
  is: its lifecycle, including an invalidation, is not overridden here.

  Runs inside the transaction that replaced the addresses and returns the first lookup or
  create error unchanged, so the caller rolls the replacement back with it: a replacement that
  committed without its alias would leave the old address recorded nowhere, and a replay would
  read the new address as the held one.
  """
  @spec retain_replaced_addresses([map()], term()) :: :ok | {:error, term()}
  def retain_replaced_addresses(replacements, actor) do
    Enum.reduce_while(replacements, :ok, fn replacement, :ok ->
      case retain_replaced_address(replacement, actor) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp retain_replaced_address(replacement, actor) do
    %{device_id: device_id, ip: ip, partition: partition, replaced_by: replaced_by} = replacement

    case DeviceAliasState.lookup_for_device(device_id, :ip, ip, actor: actor) do
      {:ok, []} -> create_replaced_address_alias(device_id, ip, partition, replaced_by, actor)
      {:ok, _existing} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp create_replaced_address_alias(device_id, ip, partition, replaced_by, actor) do
    attrs = %{
      device_id: device_id,
      partition: AliasEvents.alias_partition(partition, device_id),
      alias_type: :ip,
      alias_value: ip,
      metadata: %{"source" => @replaced_address_source, "replaced_by" => replaced_by}
    }

    case DeviceAliasState.create_detected(attrs, actor: actor) do
      {:ok, _alias_state} ->
        Logger.info(
          "SyncIngestor: kept replaced address #{ip} of #{device_id} as an alias " <>
            "(primary address now #{replaced_by})"
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp live_holders([]), do: MapSet.new()

  defp live_holders(ips) do
    from(d in Device,
      where: d.ip in ^Enum.uniq(ips) and is_nil(d.deleted_at),
      select: {d.partition, d.ip}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp present_ip?(ip) when is_binary(ip), do: String.trim(ip) != ""
  defp present_ip?(_ip), do: false

  def process_alias_updates(resolved_updates, actor) do
    confirm_threshold =
      Application.get_env(:serviceradar_core, :identity_alias_confirm_threshold, 3)

    updates =
      Enum.map(resolved_updates, fn {update, device_id} ->
        Map.put(update, :device_id, device_id)
      end)

    {:ok, _events} =
      AliasEvents.process_and_persist(updates,
        actor: actor,
        confirm_threshold: confirm_threshold
      )

    :ok
  end

  def process_alias_conflicts(resolved_updates, actor) do
    merged_ips =
      resolved_updates
      |> alias_conflict_candidates()
      |> Enum.reduce(MapSet.new(), fn {device_id, ids}, acc ->
        handle_alias_conflict(device_id, ids, actor, acc)
      end)

    if MapSet.size(merged_ips) > 0 do
      Logger.debug("SyncIngestor: merged alias conflicts for #{MapSet.size(merged_ips)} IPs")
    end

    :ok
  end

  # The pass looks an address's alias up under the partition AliasEvents records it under, the
  # device's. The identifiers of a sync naming its integration source are filed under the source's
  # own partition (Ids.identifier_partition/2), where no alias is ever recorded.
  defp alias_conflict_candidates(resolved_updates) do
    resolved_updates
    |> Enum.map(fn {update, device_id} ->
      ids = SourcePolicy.effective_identifiers(update)
      {update, device_id, ids}
    end)
    |> Enum.filter(fn {update, _device_id, ids} ->
      ids.ip != "" and alias_merge_allowed?(update, ids)
    end)
    |> Enum.map(fn {update, device_id, ids} ->
      {device_id, %{ids | partition: AliasEvents.alias_partition(update[:partition], device_id)}}
    end)
  end

  defp alias_merge_allowed?(update, ids) do
    cond do
      has_non_mac_identifier?(update, ids) -> true
      SourcePolicy.mapper_like_source?(update) -> false
      true -> false
    end
  end

  defp has_non_mac_identifier?(update, ids) do
    source_has_agent_identity? = not SourcePolicy.observer_agent_source?(update)

    (source_has_agent_identity? and ids.agent_id not in [nil, ""]) or
      ids.integration_id not in [nil, ""] or
      ids.netbox_id not in [nil, ""]
  end

  defp handle_alias_conflict(device_id, ids, actor, merged_ips) do
    if MapSet.member?(merged_ips, ids.ip) do
      merged_ips
    else
      do_handle_alias_conflict(device_id, ids, actor, merged_ips)
    end
  end

  # Alias rows are per device, so several other devices can hold a confirmed alias of the address,
  # and each is handled: an identified holder has its alias invalidated, another is merged.
  defp do_handle_alias_conflict(device_id, ids, actor, merged_ips) do
    case IdentityReconciler.lookup_alias_device_ids(ids.ip, ids.partition, actor,
           except: device_id
         ) do
      {:ok, alias_device_ids} ->
        Enum.reduce(alias_device_ids, merged_ips, fn alias_device_id, acc ->
          merge_alias_device(alias_device_id, device_id, ids, actor, acc)
        end)

      {:error, _} ->
        merged_ips
    end
  end

  defp merge_alias_device(alias_device_id, device_id, ids, actor, merged_ips) do
    cond do
      alias_device_id == device_id ->
        MapSet.put(merged_ips, ids.ip)

      IdentityReconciler.service_device_id?(alias_device_id) ->
        MapSet.put(merged_ips, ids.ip)

      not IdentityReconciler.serviceradar_uuid?(device_id) ->
        MapSet.put(merged_ips, ids.ip)

      # The alias holder owns an identifier of its own, so the shared address is the only link
      # between the two records. DHCP hands addresses to other devices; a recycled address must
      # never merge them (#4609). Stale the alias so it stops feeding merge attempts.
      IdentityReconciler.distinct_identified_devices?(alias_device_id, device_id, actor) ->
        IdentityReconciler.invalidate_ip_alias(
          ids.ip,
          ids.partition,
          alias_device_id,
          device_id,
          actor
        )

        MapSet.put(merged_ips, ids.ip)

      true ->
        attempt_alias_merge(alias_device_id, device_id, ids, actor, merged_ips)
    end
  end

  defp attempt_alias_merge(alias_device_id, device_id, ids, actor, merged_ips) do
    case IdentityReconciler.merge_devices(alias_device_id, device_id,
           actor: actor,
           reason: "ip_alias_conflict",
           details: %{
             source: "sync_ingestor",
             alias_ip: ids.ip,
             update_device_id: device_id
           }
         ) do
      :ok ->
        Logger.info(
          "SyncIngestor: merged alias device #{alias_device_id} into #{device_id} (ip=#{ids.ip})"
        )

        MapSet.put(merged_ips, ids.ip)

      {:error, {:merge_blocked, :distinct_agent_identity}} ->
        # The alias points at a device bound to a different agent — a bare IP
        # sighting must never override agent identity. Stale the alias so it
        # stops feeding merge attempts.
        IdentityReconciler.invalidate_ip_alias(
          ids.ip,
          ids.partition,
          alias_device_id,
          device_id,
          actor
        )

        MapSet.put(merged_ips, ids.ip)

      {:error, {:merge_blocked, _guard}} ->
        # Already logged and counted by the reconciler's merge guards.
        merged_ips

      {:error, reason} ->
        if alias_not_found?(reason) do
          Logger.info(
            "SyncIngestor: alias device #{alias_device_id} already merged for ip=#{ids.ip}"
          )

          MapSet.put(merged_ips, ids.ip)
        else
          Logger.warning(
            "SyncIngestor: failed to merge alias device #{alias_device_id} into #{device_id} (ip=#{ids.ip}): #{inspect(reason)}"
          )

          merged_ips
        end
    end
  end

  defp alias_not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp alias_not_found?(_), do: false
end
