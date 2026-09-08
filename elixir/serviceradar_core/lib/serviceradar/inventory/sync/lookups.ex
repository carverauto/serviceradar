defmodule ServiceRadar.Inventory.Sync.Lookups do
  @moduledoc """
  Bulk identity lookups for sync batches (identifier map, IP map, alias map)
  and per-update cached resolution.
  """

  import Ecto.Query

  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Repo

  require Logger

  @identifier_lookup_chunk_size 5_000

  # Extract all identifiers from all updates for bulk lookup
  def extract_all_identifiers(updates) do
    updates
    |> Enum.flat_map(&update_identifiers/1)
    |> Enum.uniq()
  end

  @doc """
  The `{type, value, partition}` keys one update may be looked up by.

  Shared with `matches_existing_device?/2` on purpose. A gate that decided
  "this update matched nothing" from a different identifier set than the one
  the lookup actually queried would reject updates whose identifier was never
  searched for -- and would do it silently, since a miss and a never-queried
  identifier look identical in the result map.
  """
  def update_identifiers(update) do
    ids = SourcePolicy.effective_identifiers(update)
    partition = ids.partition

    mac_values =
      if SourcePolicy.include_mac_identifier?(update) do
        ids
        |> IdentityReconciler.mac_lookup_values()
        |> Mac.lookup_macs_with_siblings()
      else
        []
      end

    update
    |> SourcePolicy.identifier_types(ids)
    |> Enum.reduce([], fn id_type, acc ->
      id_type
      |> Ids.get_identifier_values(ids)
      |> Enum.reduce(acc, &maybe_add_id(&2, id_type, &1, partition))
    end)
    |> then(fn acc ->
      Enum.reduce(mac_values, acc, &maybe_add_id(&2, :mac, &1, partition))
    end)
  end

  @doc """
  True when at least one of this update's identifiers already names a device in
  `existing_mappings` (the map returned by `bulk_lookup_identifiers/1`).

  Used by the enrichment-only gate, which must distinguish "this update
  describes a device we know" from "this update would create one".
  """
  def matches_existing_device?(update, existing_mappings) when is_map(existing_mappings) do
    update
    |> update_identifiers()
    |> Enum.any?(&Map.has_key?(existing_mappings, &1))
  end

  defp maybe_add_id(acc, _type, nil, _partition), do: acc
  defp maybe_add_id(acc, _type, "", _partition), do: acc
  defp maybe_add_id(acc, type, value, partition), do: [{type, value, partition} | acc]

  # Bulk lookup device identifiers.
  # DB connection's search_path determines the schema
  def bulk_lookup_identifiers([]), do: %{}

  def bulk_lookup_identifiers(identifiers) do
    identifiers
    |> Enum.chunk_every(@identifier_lookup_chunk_size)
    |> Enum.flat_map(&lookup_identifier_chunk/1)
    |> Enum.reduce(%{}, &identifier_row_to_map/2)
  rescue
    e ->
      Logger.warning("Bulk identifier lookup failed: #{inspect(e)}")
      %{}
  end

  defp lookup_identifier_chunk(identifiers) do
    # Build OR conditions for all identifiers
    conditions =
      Enum.map(identifiers, fn {type, value, partition} ->
        dynamic(
          [di],
          di.identifier_type == ^to_string(type) and
            di.identifier_value == ^value and
            di.partition == ^partition
        )
      end)

    combined_condition =
      Enum.reduce(conditions, fn cond, acc ->
        dynamic([di], ^acc or ^cond)
      end)

    query =
      from(di in DeviceIdentifier,
        where: ^combined_condition,
        select: {di.identifier_type, di.identifier_value, di.partition, di.device_id}
      )

    Repo.all(query)
  end

  defp identifier_row_to_map({type, value, partition, device_id}, acc) do
    type_atom =
      case type do
        type when is_binary(type) -> String.to_atom(type)
        type when is_atom(type) -> type
        _ -> nil
      end

    if type_atom == nil do
      acc
    else
      key = {type_atom, value, partition}
      Map.put(acc, key, device_id)
    end
  end

  # Bulk lookup devices by IP
  # DB connection's search_path determines the schema
  def bulk_lookup_by_ip([]), do: %{}

  def bulk_lookup_by_ip(updates) do
    ips = extract_ips(updates)

    case ips do
      [] ->
        %{}

      _ ->
        alias_map = lookup_alias_device_ids_by_ip(ips)
        direct_map = lookup_devices_by_ip(ips, alias_map)
        Map.merge(direct_map, alias_map)
    end
  rescue
    e ->
      Logger.warning("Bulk IP lookup failed: #{inspect(e)}")
      %{}
  end

  defp extract_ips(updates) do
    updates
    |> Enum.map(& &1.ip)
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.uniq()
  end

  defp lookup_devices_by_ip(ips, alias_map) do
    remaining_ips = ips -- Map.keys(alias_map)

    case remaining_ips do
      [] ->
        %{}

      _ ->
        query =
          from(d in Device,
            where: d.ip in ^remaining_ips,
            select: {d.ip, d.uid}
          )

        query
        |> Repo.all()
        |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
        |> Map.new()
    end
  end

  def lookup_alias_device_ids_by_ip(ips) do
    case Enum.filter(ips, &AliasPolicy.valid_alias_ip?/1) do
      [] ->
        %{}

      ips ->
        query =
          from(a in DeviceAliasState,
            where:
              a.alias_type == :ip and a.alias_value in ^ips and
                a.state in [:confirmed, :updated],
            select: {a.alias_value, a.device_id}
          )

        query
        |> Repo.all()
        |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
        |> Map.new()
    end
  rescue
    e ->
      Logger.warning("Bulk IP alias lookup failed: #{inspect(e)}")
      %{}
  end
end
