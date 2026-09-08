defmodule ServiceRadar.Inventory.Sync.Aliases do
  @moduledoc """
  IP alias sightings and alias-conflict merges for sync batches.
  Merges route through IdentityReconciler and inherit its stability
  guards (distinct-agent veto invalidates the alias; cooldown blocks
  oscillation).
  """

  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.SourcePolicy

  require Logger

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

  defp alias_conflict_candidates(resolved_updates) do
    resolved_updates
    |> Enum.map(fn {update, device_id} ->
      ids = SourcePolicy.effective_identifiers(update)
      {update, device_id, ids}
    end)
    |> Enum.filter(fn {update, _device_id, ids} ->
      ids.ip != "" and alias_merge_allowed?(update, ids)
    end)
    |> Enum.map(fn {_update, device_id, ids} -> {device_id, ids} end)
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

  defp do_handle_alias_conflict(device_id, ids, actor, merged_ips) do
    case IdentityReconciler.lookup_alias_device_id(ids.ip, ids.partition, actor) do
      {:ok, alias_device_id} when is_binary(alias_device_id) and alias_device_id != "" ->
        merge_alias_device(alias_device_id, device_id, ids, actor, merged_ips)

      _ ->
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
