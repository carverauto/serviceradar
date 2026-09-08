defmodule ServiceRadarWebNGWeb.DeviceLive.RemoteAccessData do
  @moduledoc false

  use ServiceRadarWebNGWeb, :verified_routes

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNGWeb.DeviceLive.MetadataData
  alias ServiceRadarWebNGWeb.FeatureFlags

  @rdp_open_permission "devices.remote_access.rdp.open"

  def can_ssh?(scope, device_row) do
    FeatureFlags.remote_access_ssh_enabled?() and ssh_capable_device?(device_row) and
      RBAC.can?(scope, "devices.remote_access.ssh.open")
  end

  def can_app?(scope) do
    FeatureFlags.remote_access_app_enabled?() and
      RBAC.can?(scope, "devices.remote_access.app.open")
  end

  def can_manage_rdp_targets?(scope, device_row) do
    FeatureFlags.remote_access_desktop_rdp_enabled?() and windows_device?(device_row) and
      RBAC.can?(scope, "settings.edge.manage")
  end

  def rdp_target_for_device(scope, device_uid) when is_binary(device_uid) do
    cond do
      not FeatureFlags.remote_access_desktop_rdp_enabled?() ->
        {:error, :disabled}

      not RBAC.can?(scope, @rdp_open_permission) ->
        {:error, :forbidden}

      true ->
        case RemoteAccessDesktopTargets.list_authorized(scope) do
          {:ok, targets} ->
            case Enum.find(targets, &authorized_device_target?(&1, device_uid)) do
              nil -> {:error, :not_found}
              target -> {:ok, target}
            end

          {:error, _reason} ->
            {:error, :unavailable}
        end
    end
  end

  def rdp_target_for_device(_scope, _device_uid), do: {:error, :not_found}

  def rdp_target_new_path(device_uid, device_row) do
    params =
      %{
        device_uid: device_uid,
        target_host: rdp_target_host(device_row),
        name: rdp_target_name(device_row),
        target_tls_server_name: rdp_target_server_name(device_row)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    ~p"/settings/networks/desktop-targets/new?#{params}"
  end

  def rdp_launch_path(device_uid) when is_binary(device_uid) do
    ~p"/devices/#{device_uid}/remote-access/rdp"
  end

  defp rdp_target_host(row) when is_map(row) do
    first_present([Map.get(row, "ip"), Map.get(row, "hostname"), Map.get(row, "name")])
  end

  defp rdp_target_host(_row), do: nil

  defp rdp_target_name(row) when is_map(row) do
    case device_display_name(row) do
      "Device" -> nil
      label -> "#{label} RDP"
    end
  end

  defp rdp_target_name(_row), do: nil

  defp rdp_target_server_name(row) when is_map(row) do
    first_present([Map.get(row, "hostname"), Map.get(row, "name")])
  end

  defp rdp_target_server_name(_row), do: nil

  defp ssh_capable_device?(nil), do: false

  defp ssh_capable_device?(device_row) when is_map(device_row) do
    values =
      device_row
      |> device_identity_values()
      |> Enum.map(&String.downcase/1)

    cond do
      Enum.any?(values, &String.contains?(&1, "windows")) ->
        false

      Enum.any?(values, &String.contains?(&1, "linux")) ->
        true

      Enum.any?(values, &String.contains?(&1, "unix")) ->
        true

      Enum.any?(values, &String.contains?(&1, "bsd")) ->
        true

      Enum.any?(values, &String.contains?(&1, "routeros")) ->
        true

      Enum.any?(values, &String.contains?(&1, "junos")) ->
        true

      Enum.any?(values, &String.contains?(&1, "ios xe")) ->
        true

      Enum.any?(values, &String.contains?(&1, "nx-os")) ->
        true

      Enum.any?(values, &String.contains?(&1, "proxmox")) ->
        true

      Enum.any?(values, &String.contains?(&1, "server")) ->
        true

      true ->
        false
    end
  end

  defp ssh_capable_device?(_device_row), do: false

  defp windows_device?(nil), do: false

  defp windows_device?(device_row) when is_map(device_row) do
    device_row
    |> device_identity_values()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&String.contains?(&1, "windows"))
  end

  defp windows_device?(_device_row), do: false

  defp authorized_device_target?(target, device_uid) when is_map(target) do
    Map.get(target, "enabled") != false and
      Map.get(target, "target_kind") == "inventory_device" and
      Map.get(target, "device_uid") == device_uid
  end

  defp authorized_device_target?(_target, _device_uid), do: false

  defp device_identity_values(device_row) when is_map(device_row) do
    Enum.flat_map(
      [
        Map.get(device_row, "type"),
        Map.get(device_row, "device_type"),
        Map.get(device_row, "os_info"),
        Map.get(device_row, "os"),
        MetadataData.value(device_row, "operating_system"),
        MetadataData.value(device_row, "os_name"),
        MetadataData.value(device_row, "os_type"),
        MetadataData.value(device_row, "platform"),
        MetadataData.value(device_row, "platform_name"),
        MetadataData.value(device_row, "sys_descr"),
        MetadataData.value(device_row, "snmp_description")
      ],
      &ssh_capability_strings/1
    )
  end

  defp device_identity_values(_device_row), do: []

  defp ssh_capability_strings(nil), do: []
  defp ssh_capability_strings(""), do: []
  defp ssh_capability_strings(value) when is_binary(value), do: [value]

  defp ssh_capability_strings(value) when is_map(value) do
    string_values =
      value
      |> Map.take(["name", "type", "version", "kernel_release", "edition"])
      |> Map.values()

    atom_values =
      value
      |> Map.take([:name, :type, :version, :kernel_release, :edition])
      |> Map.values()

    Enum.flat_map(string_values ++ atom_values, &ssh_capability_strings/1)
  end

  defp ssh_capability_strings(value), do: [to_string(value)]

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value ->
        value
    end)
  end

  defp device_display_name(nil), do: "Device"

  defp device_display_name(row) when is_map(row) do
    hostname = Map.get(row, "hostname")
    ip = Map.get(row, "ip")

    cond do
      is_binary(hostname) and hostname != "" -> hostname
      is_binary(ip) and ip != "" -> ip
      true -> "Device"
    end
  end

  defp device_display_name(_), do: "Device"
end
