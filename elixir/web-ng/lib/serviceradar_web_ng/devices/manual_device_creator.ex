defmodule ServiceRadarWebNG.Devices.ManualDeviceCreator do
  @moduledoc """
  Creates manually entered inventory devices and upserts spreadsheet fields onto
  a matching existing row (tags, metadata, hostname, and known type).
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Fence
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Devices.HostnameResolver

  require Ash.Query
  require Logger

  @partition_slug ~r/^[a-z0-9][a-z0-9_-]{0,62}$/

  @doc false
  def parse_partition(nil), do: {:ok, ""}

  def parse_partition(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" ->
        {:ok, ""}

      slug ->
        if Regex.match?(@partition_slug, slug) do
          {:ok, slug}
        else
          {:error, slug}
        end
    end
  end

  def parse_partition(_value), do: {:error, "invalid"}

  @doc false
  def coerce_partition(value) do
    case parse_partition(value) do
      {:ok, ""} -> "default"
      {:ok, slug} -> slug
      {:error, _} -> "default"
    end
  end

  @spec create(map() | nil, map()) :: {:ok, struct()} | {:error, term()}
  def create(nil, _device_data), do: {:error, :missing_scope}

  def create(scope, device_data) when is_map(device_data) do
    case upsert(scope, device_data) do
      {:ok, _kind, device} -> {:ok, device}
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates a device, or merges spreadsheet fields onto a matching inventory row.

  A match is the deterministic manual UID, the primary IP, an IP identifier, or
  hostname. Tags and metadata are merged; a known type is applied; an unknown
  CSV type such as `rids` does not clobber a richer existing type.
  """
  @spec upsert(map() | nil, map()) :: {:ok, :created | :updated, struct()} | {:error, term()}
  def upsert(nil, _device_data), do: {:error, :missing_scope}

  def upsert(scope, device_data) when is_map(device_data) do
    with {:ok, device_data} <- prepare_device_data(device_data) do
      uid = generate_device_uid(device_data.ip, device_data.partition)
      attrs = build_device_attrs(uid, device_data)

      scope
      |> find_existing_matches(uid, device_data)
      |> persist_upsert(attrs, device_data, scope)
    end
  end

  @doc false
  @spec resolve_hostname(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_hostname(hostname), do: hostname_resolver().resolve(hostname)

  defp prepare_device_data(device_data) do
    device_data =
      device_data
      |> normalize_device_data()
      |> resolve_hostname_ip()

    case device_data do
      {:error, reason} -> {:error, reason}
      data -> {:ok, data}
    end
  end

  defp normalize_device_data(device_data) do
    raw_partition = Map.get(device_data, :partition) || Map.get(device_data, "partition")

    case parse_partition(raw_partition) do
      {:ok, partition} ->
        %{
          hostname: blank_to_nil(Map.get(device_data, :hostname) || Map.get(device_data, "hostname")),
          ip: blank_to_nil(Map.get(device_data, :ip) || Map.get(device_data, "ip")),
          partition: if(partition == "", do: "default", else: partition),
          type: blank_to_nil(Map.get(device_data, :type) || Map.get(device_data, "type")),
          tags: Map.get(device_data, :tags) || Map.get(device_data, "tags") || [],
          metadata: stringify_metadata(Map.get(device_data, :metadata) || Map.get(device_data, "metadata") || %{})
        }

      {:error, slug} ->
        {:error, {:invalid_partition, slug}}
    end
  end

  defp resolve_hostname_ip({:error, _} = error), do: error

  defp resolve_hostname_ip(%{ip: ip} = device_data) when is_binary(ip), do: device_data

  defp resolve_hostname_ip(%{hostname: nil}), do: {:error, :missing_device_address}

  defp resolve_hostname_ip(%{hostname: hostname} = device_data) when is_binary(hostname) do
    case resolve_hostname(hostname) do
      {:ok, ip} -> %{device_data | ip: ip}
      {:error, reason} -> {:error, {:hostname_resolution_failed, hostname, reason}}
    end
  end

  defp resolve_hostname_ip(device_data), do: device_data

  defp build_device_attrs(uid, device_data) do
    now = DateTime.utc_now()

    %{
      uid: uid,
      hostname: device_data.hostname,
      ip: device_data.ip,
      partition: device_data.partition,
      name: device_data.hostname || device_data.ip,
      type: device_data.type,
      type_id: parse_type_id(device_data.type),
      is_managed: true,
      is_active: true,
      tags: normalize_tags(device_data.tags),
      metadata: Map.put(device_data.metadata, "type_manually_set", meaningful_type?(device_data.type)),
      discovery_sources: ["manual"],
      first_seen_time: now,
      last_seen_time: now,
      created_time: now
    }
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {:metadata, metadata} when metadata == %{} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp persist_upsert({:ok, []}, attrs, device_data, scope) do
    case create_new_device(attrs, scope) do
      {:ok, device} ->
        {:ok, :created, device}

      {:error, %Invalid{} = error} ->
        if unique_uid_error?(error) or unique_ip_error?(error) do
          retry_unique_uid_as_update(attrs, device_data, scope, error)
        else
          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp persist_upsert({:ok, matches}, attrs, device_data, scope) do
    canonical = select_canonical_match(matches)
    duplicates = duplicate_matches(matches, canonical)
    update_matched_device(canonical.device, duplicates, attrs, device_data, scope)
  end

  defp persist_upsert({:error, _} = error, _attrs, _device_data, _scope), do: error

  defp retry_unique_uid_as_update(attrs, device_data, scope, error) do
    with {:ok, []} <- lookup_by_uid(scope, Map.get(attrs, :uid)),
         {:ok, []} <- lookup_by_ip(scope, device_data.ip, device_data.partition) do
      {:error, error}
    else
      {:ok, [device | _]} ->
        update_matched_device(device, [], attrs, device_data, scope)

      {:error, _} = lookup_error ->
        lookup_error
    end
  end

  defp update_matched_device(device, duplicates, attrs, device_data, scope) do
    with {:ok, restored} <- resolve_live_target(device, scope),
         {:ok, updated} <- update_existing_device(restored, attrs, scope),
         {:ok, updated} <- maybe_merge_metadata(updated, device_data, scope),
         :ok <- merge_active_duplicates(duplicates, updated) do
      case get_reconciled_device(updated.uid, scope) do
        {:ok, reconciled} -> {:ok, :updated, reconciled}
        {:error, _} = error -> error
      end
    end
  end

  defp create_new_device(attrs, scope) do
    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope)
  end

  defp find_existing_matches(scope, uid, device_data) do
    partition = device_data.partition

    with {:ok, uid_matches} <- lookup_by_uid(scope, uid),
         {:ok, ip_matches} <- lookup_by_ip(scope, device_data.ip, partition),
         {:ok, identifier_matches} <- lookup_by_ip_identifier(scope, device_data.ip, partition),
         {:ok, hostname_matches} <- lookup_by_hostname(scope, device_data.hostname, partition) do
      matches =
        []
        |> append_matches(:uid, uid_matches)
        |> append_matches(:ip, ip_matches)
        |> append_matches(:ip_identifier, identifier_matches)
        |> append_matches(:hostname, hostname_matches)
        |> Enum.uniq_by(fn %{device: device} -> device.uid end)

      {:ok, matches}
    end
  end

  defp lookup_by_uid(scope, uid) when is_binary(uid) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^uid)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp lookup_by_uid(_scope, _uid), do: {:ok, []}

  defp lookup_by_ip(scope, ip, partition) when is_binary(ip) and is_binary(partition) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(ip == ^ip and partition == ^partition)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp lookup_by_ip(_scope, _ip, _partition), do: {:ok, []}

  defp lookup_by_hostname(scope, hostname, partition) when is_binary(hostname) and is_binary(partition) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(hostname == ^hostname and partition == ^partition)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp lookup_by_hostname(_scope, _hostname, _partition), do: {:ok, []}

  defp lookup_by_ip_identifier(scope, ip, partition) when is_binary(ip) and is_binary(partition) do
    DeviceIdentifier
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(identifier_type == :ip and identifier_value == ^ip and partition == ^partition)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
    |> case do
      {:ok, identifiers} ->
        identifiers
        |> Enum.map(& &1.device_id)
        |> Enum.uniq()
        |> load_identifier_devices(scope)

      {:error, _} = error ->
        error
    end
  end

  defp lookup_by_ip_identifier(_scope, _ip, _partition), do: {:ok, []}

  defp load_identifier_devices([], _scope), do: {:ok, []}

  defp load_identifier_devices(uids, scope) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp append_matches(matches, reason, devices) do
    matches ++ Enum.map(devices, &%{reason: reason, device: &1})
  end

  defp select_canonical_match(matches) do
    Enum.min_by(matches, &canonical_rank/1)
  end

  # Live rows always beat tombstones. A uid match on a merged-away device used
  # to rank 0 and then :restore, which races identity recon (StaleRecord) and
  # can undo a merge. Prefer the live IP/hostname survivor.
  defp canonical_rank(%{reason: :uid, device: %{deleted_at: nil}}), do: 0
  defp canonical_rank(%{reason: :ip, device: %{deleted_at: nil}}), do: 1
  defp canonical_rank(%{reason: :ip_identifier, device: %{deleted_at: nil}}), do: 2
  defp canonical_rank(%{reason: :hostname, device: %{deleted_at: nil}}), do: 3
  defp canonical_rank(%{reason: :uid}), do: 4
  defp canonical_rank(%{reason: :ip}), do: 5
  defp canonical_rank(%{reason: :ip_identifier}), do: 6
  defp canonical_rank(%{reason: :hostname}), do: 7
  defp canonical_rank(_match), do: 8

  defp duplicate_matches(matches, canonical) do
    matches
    |> Enum.reject(fn %{device: device} -> device.uid == canonical.device.uid end)
    |> Enum.uniq_by(fn %{device: device} -> device.uid end)
  end

  defp resolve_live_target(%Device{deleted_at: nil} = device, _scope), do: {:ok, device}

  defp resolve_live_target(%Device{uid: uid} = device, scope) do
    case reload_follow_canonical(uid, scope) do
      {:ok, %Device{deleted_at: nil} = live} ->
        {:ok, live}

      {:ok, %Device{} = tombstoned} ->
        restore_deleted(tombstoned, scope)

      {:error, :not_found} ->
        restore_deleted(device, scope)

      {:error, _} = error ->
        error
    end
  end

  # Atomic Ash.update on a tombstoned row raises StaleRecord because the
  # primary read filters deleted_at. Restore through include_deleted bulk
  # update, same as MergeEngine.recreate_device/3.
  defp restore_deleted(%Device{uid: uid} = device, scope) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^uid)

    case Ash.bulk_update(query, :restore, %{},
           scope: scope,
           return_errors?: true,
           return_records?: true
         ) do
      %Ash.BulkResult{status: :success, records: [restored | _]} ->
        {:ok, restored}

      %Ash.BulkResult{status: :success} ->
        Device.get_by_uid(uid, false, scope: scope)

      %Ash.BulkResult{errors: [error | _]} ->
        {:error, error}

      %Ash.BulkResult{errors: []} ->
        Device.get_by_uid(uid, false, scope: scope)

      other ->
        Logger.warning("Failed to restore #{uid} for CSV/manual upsert: #{inspect(other)}")
        {:error, {:restore_failed, device.uid}}
    end
  end

  defp reload_follow_canonical(uid, scope) when is_binary(uid) do
    actor = SystemActor.system(:manual_device_readd)
    canonical_uid = IdentityReconciler.follow_canonical_device_id(uid, actor)

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^canonical_uid)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
    |> case do
      {:ok, [found | _]} -> {:ok, found}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc false
  def update_existing_device(%Device{} = device, attrs, scope) do
    update_attrs = additional_update_attrs(device, attrs)

    Repo.transaction(fn ->
      with {:ok, device} <- put_type_ownership(device, update_attrs),
           {:ok, updated} <-
             device
             |> Ash.Changeset.for_update(:update, update_attrs)
             |> Ash.update(scope: scope) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  # Merge policy for an existing inventory row: incoming tags/sources are added,
  # hostname is applied, IP fills only when blank, and an unknown CSV type does
  # not replace a richer existing type.
  def additional_update_attrs(device, attrs) when is_map(attrs) do
    incoming_tags = Map.get(attrs, :tags, %{})
    incoming_sources = Map.get(attrs, :discovery_sources, ["manual"])

    %{}
    |> put_if_present(:last_seen_time, Map.get(attrs, :last_seen_time))
    |> Map.put(:is_active, true)
    |> maybe_put_hostname(device, attrs)
    |> maybe_put_ip(device, attrs)
    |> maybe_put_type(device, attrs)
    |> Map.put(:tags, merge_tags(Map.get(device, :tags), incoming_tags))
    |> Map.put(
      :discovery_sources,
      merge_discovery_sources(Map.get(device, :discovery_sources), incoming_sources)
    )
  end

  defp put_type_ownership(device, update) do
    submitted_ownership =
      case Map.fetch(update, :type) do
        {:ok, type} -> meaningful_type?(type)
        :error -> nil
      end

    case Repo.query(
           """
           UPDATE platform.ocsf_devices
           SET metadata = COALESCE(metadata, '{}'::jsonb) ||
             jsonb_build_object('type_manually_set', COALESCE(
               $2::boolean,
               metadata->'type_manually_set' = 'true'::jsonb,
               'manual' = ANY(COALESCE(discovery_sources, ARRAY[]::text[]))
                 AND lower(COALESCE(NULLIF(btrim(type), ''), 'unknown')) <> 'unknown'
             ))
           WHERE uid = $1
           RETURNING metadata, type, type_id
           """,
           [device.uid, submitted_ownership]
         ) do
      {:ok, %{rows: [[metadata, type, type_id]]}} ->
        {:ok, %{device | metadata: metadata, type: type, type_id: type_id}}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp meaningful_type?(type) when is_binary(type), do: String.downcase(String.trim(type)) not in ["", "unknown"]

  defp meaningful_type?(_type), do: false

  defp maybe_put_hostname(update, _device, attrs) do
    case Map.get(attrs, :hostname) do
      hostname when is_binary(hostname) and hostname != "" ->
        Map.merge(update, %{hostname: hostname, name: hostname})

      _ ->
        update
    end
  end

  defp maybe_put_ip(update, device, attrs) do
    incoming = Map.get(attrs, :ip)

    if present?(incoming) and blank?(Map.get(device, :ip)) do
      Map.put(update, :ip, incoming)
    else
      update
    end
  end

  defp maybe_put_type(update, device, attrs) do
    incoming_type = Map.get(attrs, :type)
    incoming_type_id = Map.get(attrs, :type_id, parse_type_id(incoming_type))

    cond do
      not present?(incoming_type) ->
        update

      known_type_id?(incoming_type_id) ->
        Map.merge(update, %{type: incoming_type, type_id: incoming_type_id})

      blank?(Map.get(device, :type)) ->
        Map.merge(update, %{type: incoming_type, type_id: incoming_type_id || 0})

      true ->
        update
    end
  end

  defp maybe_merge_metadata(device, %{metadata: metadata}, scope) when is_map(metadata) and map_size(metadata) > 0 do
    device
    |> Ash.Changeset.for_update(:merge_metadata, %{
      metadata_patch: Map.delete(metadata, "type_manually_set")
    })
    |> Ash.update(scope: scope)
  end

  defp maybe_merge_metadata(device, _device_data, _scope), do: {:ok, device}

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp known_type_id?(type_id) when is_integer(type_id) and type_id > 0, do: true
  defp known_type_id?(_type_id), do: false

  defp merge_active_duplicates(duplicates, canonical) do
    duplicates
    |> Enum.filter(fn %{device: device} -> is_nil(device.deleted_at) end)
    |> Enum.reduce_while(:ok, fn %{device: device}, :ok ->
      case IdentityReconciler.merge_devices(device.uid, canonical.uid,
             actor: SystemActor.system(:manual_device_readd),
             reason: "manual_device_readd",
             details: %{
               "hostname" => canonical.hostname,
               "ip" => canonical.ip,
               "source" => "manual_device_creator"
             }
           ) do
        :ok ->
          {:cont, :ok}

        {:error, {:merge_blocked, guard}} ->
          Logger.warning(
            "CSV/manual upsert left duplicate #{device.uid} beside #{canonical.uid} " <>
              "(merge blocked: #{guard})"
          )

          {:cont, :ok}

        {:error, reason} = error ->
          if Fence.stale?(reason) do
            Logger.warning("CSV/manual upsert skipped duplicate #{device.uid}: stale after identity change")

            {:cont, :ok}
          else
            {:halt, error}
          end

        other ->
          {:halt, {:error, other}}
      end
    end)
  end

  defp get_reconciled_device(uid, scope) do
    Device.get_by_uid(uid, false, scope: scope)
  end

  # `default` keeps the historical `manual:<ip>` seed so re-importing isolation
  # copies still matches the devices already in inventory. Other partitions
  # include the slug so the same address can exist as a second live device.
  defp generate_device_uid(ip, partition) when is_binary(ip) do
    seed =
      case coerce_partition(partition) do
        "default" -> "manual:#{ip}"
        other -> "manual:#{other}:#{ip}"
      end

    :sha256
    |> :crypto.hash(seed)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp generate_device_uid(_ip, _partition), do: Ash.UUID.generate()

  defp hostname_resolver do
    Application.get_env(:serviceradar_web_ng, :device_hostname_resolver, HostnameResolver)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp stringify_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case stringify_metadata_value(value) do
        nil -> acc
        string_value -> Map.put(acc, to_string(key), string_value)
      end
    end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp stringify_metadata_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stringify_metadata_value(nil), do: nil
  defp stringify_metadata_value(value), do: value

  defp parse_type_id(nil), do: 0
  defp parse_type_id(""), do: 0
  defp parse_type_id("server"), do: 1
  defp parse_type_id("Server"), do: 1
  defp parse_type_id("desktop"), do: 2
  defp parse_type_id("Desktop"), do: 2
  defp parse_type_id("laptop"), do: 3
  defp parse_type_id("Laptop"), do: 3
  defp parse_type_id("switch"), do: 10
  defp parse_type_id("Switch"), do: 10
  defp parse_type_id("router"), do: 12
  defp parse_type_id("Router"), do: 12
  defp parse_type_id("firewall"), do: 9
  defp parse_type_id("Firewall"), do: 9
  defp parse_type_id(_type), do: 0

  defp normalize_tags(nil), do: %{}
  defp normalize_tags(tags) when is_map(tags), do: tags

  defp normalize_tags(tags) when is_list(tags) do
    Enum.reduce(tags, %{}, fn tag, acc ->
      case String.split(tag, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        [key] -> Map.put(acc, String.trim(key), nil)
      end
    end)
  end

  defp normalize_tags(_tags), do: %{}

  defp merge_tags(existing, incoming) do
    Map.merge(normalize_tags(existing), normalize_tags(incoming))
  end

  defp merge_discovery_sources(existing, incoming) do
    (List.wrap(existing) ++ List.wrap(incoming) ++ ["manual"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp unique_uid_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &unique_uid_error_detail?/1)
  end

  defp unique_uid_error?(_error), do: false

  defp unique_ip_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &unique_ip_error_detail?/1)
  end

  defp unique_ip_error?(_error), do: false

  defp unique_ip_error_detail?(error) do
    fields = List.wrap(Map.get(error, :fields, [])) ++ List.wrap(Map.get(error, :field))
    constraint = to_string(Map.get(error, :constraint) || Map.get(error, :constraint_name) || "")
    message = to_string(Map.get(error, :message) || "")

    Enum.member?(fields, :ip) or
      String.contains?(constraint, "ocsf_devices_unique_active_ip_idx") or
      String.contains?(message, "ocsf_devices_unique_active_ip_idx")
  end

  defp unique_uid_error_detail?(%InvalidAttribute{} = error) do
    field = Map.get(error, :field)
    validation = Map.get(error, :validation)
    message = Map.get(error, :message)

    field == :uid and
      (unique_validation?(validation) or
         (is_binary(message) and String.contains?(message, "has already been taken")))
  end

  defp unique_uid_error_detail?(%Ash.Error.Changes.InvalidChanges{} = error) do
    fields = Map.get(error, :fields, [])
    validation = Map.get(error, :validation)
    message = Map.get(error, :message)

    Enum.member?(List.wrap(fields), :uid) and
      (unique_validation?(validation) or
         (is_binary(message) and String.contains?(message, "has already been taken")))
  end

  defp unique_uid_error_detail?(_error), do: false

  defp unique_validation?(:unique), do: true
  defp unique_validation?({Ash.Resource.Validation.Uniqueness, _opts}), do: true
  defp unique_validation?(_validation), do: false
end
