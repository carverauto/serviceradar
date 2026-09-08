defmodule ServiceRadarWebNGWeb.DeviceLive.VirtualizationData do
  @moduledoc false

  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem

  require Ash.Query
  require Logger

  def load_virtualization_summary(nil, _device_uid), do: nil

  def load_virtualization_summary(scope, device_uid) do
    host = load_virtualization_host(scope, device_uid)
    guest = load_virtualization_guest(scope, device_uid)

    cond do
      host ->
        host_id = host.id

        %{
          kind: :host,
          host: host,
          cluster: load_virtualization_cluster(scope, host.cluster_id),
          guest: nil,
          datastores: load_virtualization_datastores(scope, host_id),
          disks: load_virtualization_disks(scope, host_id),
          network_interfaces: load_virtualization_network_interfaces(scope, host_id),
          storage_systems: load_virtualization_storage_systems(scope, host_id),
          guests: load_virtualization_guests_for_host(scope, host_id)
        }

      guest ->
        %{
          kind: :guest,
          host: nil,
          # Resolve the guest's parent hypervisor node so the details page can
          # link back to the host device (proxmox guests know their node).
          parent_host: load_virtualization_host_by_id(scope, guest.host_id),
          cluster: nil,
          guest: guest,
          datastores: [],
          disks: [],
          network_interfaces: load_virtualization_network_interfaces_for_guest(scope, guest.id),
          storage_systems: [],
          guests: []
        }

      true ->
        nil
    end
  rescue
    error ->
      Logger.warning("Failed to load virtualization summary for #{device_uid}: #{inspect(error)}")

      nil
  end

  defp load_virtualization_host(scope, device_uid) do
    VirtualizationHost
    |> virtualization_query(scope)
    |> Ash.Query.filter(device_uid == ^device_uid)
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_guest(scope, device_uid) do
    VirtualizationGuest
    |> virtualization_query(scope)
    |> Ash.Query.filter(device_uid == ^device_uid)
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_host_by_id(_scope, nil), do: nil

  defp load_virtualization_host_by_id(scope, host_id) do
    VirtualizationHost
    |> virtualization_query(scope)
    |> Ash.Query.filter(id == ^host_id)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_cluster(_scope, nil), do: nil

  defp load_virtualization_cluster(scope, cluster_id) do
    VirtualizationCluster
    |> virtualization_query(scope)
    |> Ash.Query.filter(id == ^cluster_id)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_datastores(scope, host_id) do
    VirtualizationDatastore
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(24)
    |> ash_read_many(scope)
  end

  defp load_virtualization_disks(scope, host_id) do
    VirtualizationHostDisk
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.limit(24)
    |> ash_read_many(scope)
  end

  defp load_virtualization_network_interfaces(scope, host_id) do
    VirtualizationNetworkInterface
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(32)
    |> ash_read_many(scope)
  end

  defp load_virtualization_network_interfaces_for_guest(scope, guest_id) do
    VirtualizationNetworkInterface
    |> virtualization_query(scope)
    |> Ash.Query.filter(guest_id == ^guest_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(32)
    |> ash_read_many(scope)
  end

  defp load_virtualization_storage_systems(scope, host_id) do
    VirtualizationStorageSystem
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(16)
    |> ash_read_many(scope)
  end

  defp load_virtualization_guests_for_host(scope, host_id) do
    VirtualizationGuest
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(100)
    |> ash_read_many(scope)
  end

  defp virtualization_query(resource, nil), do: Ash.Query.for_read(resource, :read, %{})

  defp virtualization_query(resource, scope), do: Ash.Query.for_read(resource, :read, %{}, scope: scope)

  defp ash_read_first(query, scope) do
    case ash_read_many(query, scope) do
      [first | _] -> first
      _ -> nil
    end
  end

  defp ash_read_many(query, scope) do
    result =
      if scope do
        Ash.read(query, scope: scope)
      else
        Ash.read(query)
      end

    case result do
      {:ok, rows} when is_list(rows) -> rows
      {:ok, %Ash.Page.Keyset{results: rows}} -> rows
      {:ok, %Ash.Page.Offset{results: rows}} -> rows
      _ -> []
    end
  end
end
