defmodule ServiceRadar.Edge.RemoteConsoleTargetResolver do
  @moduledoc """
  Resolves provider-specific inventory rows into remote-console target metadata.

  Console session resources can remain provider-specific while this module owns
  provider target inference. That keeps session lifecycle code separate from
  hypervisor inventory shape and gives future providers a common boundary.
  """

  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @proxmox_provider "proxmox"
  @proxmox_target_kinds [:pve_host, :qemu_guest, :lxc_guest]
  @proxmox_console_modes [:ssh, :proxmox_termproxy, :proxmox_vncwebsocket]
  @proxmox_enabled_console_modes [:ssh]

  @type proxmox_target :: %{
          target_kind: :pve_host | :qemu_guest | :lxc_guest,
          console_mode: :ssh | :proxmox_termproxy | :proxmox_vncwebsocket,
          provider_ref: String.t() | nil
        }

  @doc """
  Resolves a Proxmox console target from a canonical device and request.
  """
  @spec resolve_proxmox(map(), map(), keyword()) :: {:ok, proxmox_target()} | {:error, atom()}
  def resolve_proxmox(device, request, opts \\ []) when is_map(device) and is_map(request) do
    ash_opts = Keyword.get(opts, :ash_opts, [])
    lookup = Keyword.get(opts, :virtualization_lookup, &virtualization_by_device/3)

    requested_kind =
      normalize_target_kind(Map.get(request, :target_kind) || Map.get(request, "target_kind"))

    requested_mode =
      normalize_console_mode(Map.get(request, :console_mode) || Map.get(request, "console_mode"))

    with {:ok, inferred_kind} <- infer_target_kind(device, ash_opts, lookup),
         {:ok, target_kind} <- pick_target_kind(requested_kind, inferred_kind),
         {:ok, console_mode} <- pick_console_mode(requested_mode, target_kind) do
      {:ok,
       %{
         target_kind: target_kind,
         console_mode: console_mode,
         provider_ref: provider_ref_for_target(device, target_kind, ash_opts, lookup)
       }}
    end
  end

  defp infer_target_kind(device, ash_opts, lookup) do
    case lookup.(VirtualizationHost, device_uid(device), ash_opts) do
      {:ok, hosts} ->
        if Enum.any?(hosts, &proxmox_row?/1) do
          {:ok, :pve_host}
        else
          infer_guest_target_kind(device, ash_opts, lookup)
        end

      {:error, _reason} ->
        infer_target_kind_from_device(device)
    end
  end

  defp infer_guest_target_kind(device, ash_opts, lookup) do
    case lookup.(VirtualizationGuest, device_uid(device), ash_opts) do
      {:ok, guests} ->
        guests
        |> Enum.find(&proxmox_row?/1)
        |> case do
          nil -> infer_target_kind_from_device(device)
          guest -> {:ok, guest_target_kind(guest)}
        end

      {:error, _reason} ->
        infer_target_kind_from_device(device)
    end
  end

  defp virtualization_by_device(resource, device_uid, ash_opts) do
    resource
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid})
    |> Ash.read(ash_opts)
  end

  defp provider_ref_for_target(device, :pve_host, ash_opts, lookup) do
    VirtualizationHost
    |> lookup.(device_uid(device), ash_opts)
    |> provider_ref_from_rows()
  end

  defp provider_ref_for_target(device, target_kind, ash_opts, lookup)
       when target_kind in [:qemu_guest, :lxc_guest] do
    VirtualizationGuest
    |> lookup.(device_uid(device), ash_opts)
    |> provider_ref_from_rows(&guest_matches_target_kind?(&1, target_kind))
  end

  defp provider_ref_for_target(_device, _target_kind, _ash_opts, _lookup), do: nil

  defp provider_ref_from_rows(result, predicate \\ fn _row -> true end)

  defp provider_ref_from_rows({:ok, rows}, predicate) when is_list(rows) do
    rows
    |> Enum.find(&(proxmox_row?(&1) and predicate.(&1)))
    |> case do
      nil -> nil
      row -> value_string(row, [:provider_ref, "provider_ref"])
    end
  end

  defp provider_ref_from_rows(_result, _predicate), do: nil

  defp proxmox_row?(row), do: value_string(row, [:provider, "provider"]) == @proxmox_provider

  defp guest_matches_target_kind?(row, :lxc_guest),
    do: value_string(row, [:guest_type, "guest_type"]) in ["lxc", "container"]

  defp guest_matches_target_kind?(row, :qemu_guest),
    do: value_string(row, [:guest_type, "guest_type"]) in ["qemu", "vm"]

  defp guest_target_kind(row) do
    case value_string(row, [:guest_type, "guest_type"]) do
      guest_type when guest_type in ["lxc", "container"] -> :lxc_guest
      _guest_type -> :qemu_guest
    end
  end

  defp infer_target_kind_from_device(%{vendor_name: vendor}) when is_binary(vendor) do
    if String.downcase(vendor) =~ "proxmox",
      do: {:ok, :pve_host},
      else: {:error, :unsupported_console_target}
  end

  defp infer_target_kind_from_device(%{metadata: metadata}) when is_map(metadata) do
    case ValueUtils.string_value(metadata, [
           "proxmox_guest_type",
           :proxmox_guest_type,
           "guest_type",
           :guest_type
         ]) do
      "lxc" -> {:ok, :lxc_guest}
      "qemu" -> {:ok, :qemu_guest}
      _ -> {:error, :unsupported_console_target}
    end
  end

  defp infer_target_kind_from_device(_device), do: {:error, :unsupported_console_target}

  defp pick_target_kind(nil, inferred), do: {:ok, inferred}
  defp pick_target_kind(kind, _inferred) when kind in @proxmox_target_kinds, do: {:ok, kind}
  defp pick_target_kind(_kind, _inferred), do: {:error, :unsupported_console_target}

  defp pick_console_mode(nil, :pve_host), do: {:ok, :ssh}

  defp pick_console_mode(:ssh, :pve_host) when :ssh in @proxmox_enabled_console_modes,
    do: {:ok, :ssh}

  defp pick_console_mode(mode, _target_kind) when mode in @proxmox_console_modes,
    do: {:error, :unsupported_console_mode}

  defp pick_console_mode(_mode, _target_kind), do: {:error, :unsupported_console_mode}

  defp normalize_target_kind(value) when is_atom(value) and value in @proxmox_target_kinds,
    do: value

  defp normalize_target_kind("pve_host"), do: :pve_host
  defp normalize_target_kind("qemu_guest"), do: :qemu_guest
  defp normalize_target_kind("lxc_guest"), do: :lxc_guest
  defp normalize_target_kind(_value), do: nil

  defp normalize_console_mode(value) when is_atom(value) and value in @proxmox_console_modes,
    do: value

  defp normalize_console_mode("ssh"), do: :ssh
  defp normalize_console_mode("proxmox_termproxy"), do: :proxmox_termproxy
  defp normalize_console_mode("proxmox_vncwebsocket"), do: :proxmox_vncwebsocket
  defp normalize_console_mode(_value), do: nil

  defp device_uid(device), do: value_string(device, [:uid, "uid", :device_uid, "device_uid"])

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)
end
