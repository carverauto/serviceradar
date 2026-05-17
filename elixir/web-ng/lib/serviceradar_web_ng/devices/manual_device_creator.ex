defmodule ServiceRadarWebNG.Devices.ManualDeviceCreator do
  @moduledoc """
  Creates manually entered inventory devices.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Devices.HostnameResolver

  @spec create(map() | nil, map()) :: {:ok, struct()} | {:error, term()}
  def create(nil, _device_data), do: {:error, :missing_scope}

  def create(scope, device_data) when is_map(device_data) do
    with {:ok, device_data} <- prepare_device_data(device_data) do
      device_data.ip
      |> generate_device_uid()
      |> create_new_device(device_data, scope)
      |> normalize_create_result()
    end
  end

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
    case hostname_resolver().resolve(hostname) do
      {:ok, ip} -> %{device_data | ip: ip}
      {:error, reason} -> {:error, {:hostname_resolution_failed, hostname, reason}}
    end
  end

  defp resolve_hostname_ip(device_data), do: device_data

  defp create_new_device(uid, device_data, scope) do
    now = DateTime.utc_now()

    attrs =
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

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope)
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
