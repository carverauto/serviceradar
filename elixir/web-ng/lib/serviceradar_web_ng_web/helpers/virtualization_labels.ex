defmodule ServiceRadarWebNGWeb.Helpers.VirtualizationLabels do
  @moduledoc false

  @empty_inventory_label "No hypervisor inventory"

  def provider_label(%{provider: provider}), do: provider_label(provider)

  def provider_label(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "proxmox" ->
        "Proxmox"

      "vsphere" ->
        "vSphere"

      "vcenter" ->
        "vCenter"

      "vmware" ->
        "VMware"

      "" ->
        "Hypervisor"

      value ->
        value
        |> String.replace(["_", "-"], " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  def provider_label(_provider), do: "Hypervisor"

  def provider_summary(rows, empty_label \\ @empty_inventory_label)

  def provider_summary(rows, empty_label) when is_list(rows) do
    providers =
      rows
      |> Enum.map(&provider_from_row/1)
      |> Enum.filter(&present?/1)
      |> Enum.map(&provider_label/1)
      |> Enum.uniq()

    case providers do
      [] -> empty_label
      [provider] -> provider
      [first | rest] -> "#{first} +#{length(rest)}"
    end
  end

  def provider_summary(_rows, empty_label), do: empty_label

  defp provider_from_row(%{provider: provider}), do: provider
  defp provider_from_row(%{"provider" => provider}), do: provider
  defp provider_from_row(_row), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
