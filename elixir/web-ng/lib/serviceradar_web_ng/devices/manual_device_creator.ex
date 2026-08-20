defmodule ServiceRadarWebNG.Devices.ManualDeviceCreator do
  @moduledoc """
  Creates manually entered inventory devices.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadarWebNG.Devices.HostnameResolver

  require Ash.Query

  @spec create(map() | nil, map()) :: {:ok, struct()} | {:error, term()}
  def create(nil, _device_data), do: {:error, :missing_scope}

  def create(scope, device_data) when is_map(device_data) do
    with {:ok, device_data} <- prepare_device_data(device_data) do
      uid = generate_device_uid(device_data.ip)
      attrs = build_device_attrs(uid, device_data)

      scope
      |> find_existing_matches(uid, device_data)
      |> create_or_reconcile_device(attrs, scope)
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
    %{
      hostname: blank_to_nil(Map.get(device_data, :hostname) || Map.get(device_data, "hostname")),
      ip: blank_to_nil(Map.get(device_data, :ip) || Map.get(device_data, "ip")),
      type: blank_to_nil(Map.get(device_data, :type) || Map.get(device_data, "type")),
      tags: Map.get(device_data, :tags) || Map.get(device_data, "tags") || []
    }
  end

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
      name: device_data.hostname || device_data.ip,
      type: device_data.type,
      type_id: parse_type_id(device_data.type),
      is_managed: true,
      is_active: true,
      tags: normalize_tags(device_data.tags),
      discovery_sources: ["manual"],
      first_seen_time: now,
      last_seen_time: now,
      created_time: now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp create_or_reconcile_device({:ok, []}, attrs, scope) do
    attrs
    |> create_new_device(scope)
    |> normalize_create_result()
  end

  defp create_or_reconcile_device({:ok, matches}, attrs, scope) do
    canonical = select_canonical_match(matches)
    duplicates = duplicate_matches(matches, canonical)

    with {:ok, restored} <- restore_if_deleted(canonical.device, scope),
         {:ok, updated} <- update_existing_device(restored, attrs, scope),
         :ok <- merge_active_duplicates(duplicates, updated) do
      get_reconciled_device(updated.uid, scope)
    end
  end

  defp create_or_reconcile_device({:error, _} = error, _attrs, _scope), do: error

  defp create_new_device(attrs, scope) do
    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope)
  end

  defp find_existing_matches(scope, uid, device_data) do
    with {:ok, uid_matches} <- lookup_by_uid(scope, uid),
         {:ok, ip_matches} <- lookup_by_ip(scope, device_data.ip),
         {:ok, hostname_matches} <- lookup_by_hostname(scope, device_data.hostname) do
      matches =
        []
        |> append_matches(:uid, uid_matches)
        |> append_matches(:ip, ip_matches)
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

  defp lookup_by_ip(scope, ip) when is_binary(ip) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(ip == ^ip)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp lookup_by_ip(_scope, _ip), do: {:ok, []}

  defp lookup_by_hostname(scope, hostname) when is_binary(hostname) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(hostname == ^hostname)
    |> Ash.read(scope: scope)
    |> Page.unwrap()
  end

  defp lookup_by_hostname(_scope, _hostname), do: {:ok, []}

  defp append_matches(matches, reason, devices) do
    matches ++ Enum.map(devices, &%{reason: reason, device: &1})
  end

  defp select_canonical_match(matches) do
    Enum.min_by(matches, &canonical_rank/1)
  end

  defp canonical_rank(%{reason: :uid}), do: 0
  defp canonical_rank(%{reason: :ip, device: %{deleted_at: nil}}), do: 1
  defp canonical_rank(%{reason: :hostname, device: %{deleted_at: nil}}), do: 2
  defp canonical_rank(%{reason: :ip}), do: 3
  defp canonical_rank(%{reason: :hostname}), do: 4
  defp canonical_rank(_match), do: 5

  defp duplicate_matches(matches, canonical) do
    matches
    |> Enum.reject(fn %{device: device} -> device.uid == canonical.device.uid end)
    |> Enum.uniq_by(fn %{device: device} -> device.uid end)
  end

  defp restore_if_deleted(%Device{deleted_at: nil} = device, _scope), do: {:ok, device}

  defp restore_if_deleted(%Device{} = device, scope) do
    device
    |> Ash.Changeset.for_update(:restore, %{})
    |> Ash.update(scope: scope)
  end

  defp update_existing_device(%Device{} = device, attrs, scope) do
    update_attrs = existing_device_update_attrs(device, attrs)

    device
    |> Ash.Changeset.for_update(:update, update_attrs)
    |> Ash.update(scope: scope)
  end

  defp existing_device_update_attrs(device, attrs) do
    attrs
    |> Map.take([
      :hostname,
      :ip,
      :name,
      :type,
      :type_id,
      :is_managed,
      :is_active,
      :last_seen_time,
      :tags,
      :discovery_sources
    ])
    |> Map.update(:tags, %{}, &merge_tags(device.tags, &1))
    |> Map.update(:discovery_sources, ["manual"], &merge_discovery_sources(device.discovery_sources, &1))
  end

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
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  defp get_reconciled_device(uid, scope) do
    Device.get_by_uid(uid, false, scope: scope)
  end

  defp normalize_create_result({:ok, device}), do: {:ok, device}

  defp normalize_create_result({:error, %Invalid{} = error}) do
    if unique_uid_error?(error), do: {:error, :already_exists}, else: {:error, error}
  end

  defp normalize_create_result({:error, error}), do: {:error, error}

  defp generate_device_uid(ip) when is_binary(ip) do
    :sha256
    |> :crypto.hash("manual:#{ip}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp generate_device_uid(_ip), do: Ash.UUID.generate()

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
