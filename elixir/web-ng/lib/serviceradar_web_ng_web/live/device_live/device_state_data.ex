defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceStateData do
  @moduledoc false

  use ServiceRadarWebNGWeb, :verified_routes

  def ansible_managed?(%{ansible_managed: true}), do: true
  def ansible_managed?(%{"ansible_managed" => true}), do: true
  def ansible_managed?(_), do: false

  def deleted?(row) when is_map(row) do
    value = Map.get(row, "deleted_at")
    not is_nil(value) and value != ""
  end

  def deleted?(_), do: false

  def agent?(row) when is_map(row) do
    row
    |> linked_agent_list()
    |> Enum.any?()
  end

  def agent?(_), do: false

  def display_name(nil), do: "Device"

  def display_name(row) when is_map(row) do
    hostname = Map.get(row, "hostname")
    ip = Map.get(row, "ip")

    cond do
      is_binary(hostname) and hostname != "" -> hostname
      is_binary(ip) and ip != "" -> ip
      true -> "Device"
    end
  end

  def display_name(_), do: "Device"

  def proxmox_console_target?(%{kind: :host, host: %{provider: "proxmox"}}), do: true
  def proxmox_console_target?(_summary), do: false

  def proxmox_console_action_label(%{kind: :host}), do: "Open PVE shell"
  def proxmox_console_action_label(_summary), do: "Open console"

  def proxmox_console_path(device_uid, %{kind: :host}) do
    ~p"/devices/#{device_uid}/proxmox-console?#{[target_kind: "pve_host", console_mode: "proxmox_termproxy"]}"
  end

  def proxmox_console_path(device_uid, _summary), do: ~p"/devices/#{device_uid}/proxmox-console"

  def deleted_by_from_scope(%{user: user}) when is_map(user) do
    Map.get(user, :email) || Map.get(user, :id)
  end

  def deleted_by_from_scope(_), do: nil

  defp linked_agent_list(row) when is_map(row) do
    row
    |> agent_list()
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp linked_agent_list(_), do: []

  defp agent_list(row) when is_map(row), do: Map.get(row, "agent_list") || Map.get(row, :agent_list) || []
end
