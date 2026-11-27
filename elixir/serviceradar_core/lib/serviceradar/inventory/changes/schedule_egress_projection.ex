defmodule ServiceRadar.Inventory.Changes.ScheduleEgressProjection do
  @moduledoc """
  Ash change that schedules Internet egress Dgraph stitch reconciliation when
  manual egress fields change on `InterfaceSettings` or `Device.tags`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.EgressStitch
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Store
  alias ServiceRadar.NetworkDiscovery.TopologyProjectionWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  @egress_fields [
    :internet_egress,
    :egress_upstream_asn,
    :egress_vantage_id,
    :egress_port_speed_mbps
  ]

  @impl true
  def change(changeset, _opts, _context) do
    if egress_changed?(changeset) do
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        schedule_for_record(record)
        {:ok, record}
      end)
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp egress_changed?(%{data: %InterfaceSettings{}} = changeset) do
    Enum.any?(@egress_fields, &Ash.Changeset.changing_attribute?(changeset, &1)) or
      Ash.Changeset.get_attribute(changeset, :internet_egress) == true
  end

  defp egress_changed?(%{data: %Device{}} = changeset) do
    Ash.Changeset.changing_attribute?(changeset, :tags)
  end

  defp egress_changed?(_changeset), do: false

  defp schedule_for_record(%InterfaceSettings{device_id: device_id}) when is_binary(device_id) do
    dispatch_device_reconcile(device_id)
  end

  defp schedule_for_record(%Device{uid: device_uid}) when is_binary(device_uid) do
    dispatch_device_reconcile(device_uid)
  end

  defp schedule_for_record(_record), do: :ok

  defp dispatch_device_reconcile(device_id) do
    cond do
      ObanSupport.available?() ->
        TopologyProjectionWorker.enqueue(:interfaces, [%{device_id: device_id}])

      Store.writable?() and Process.whereis(Repo) != nil ->
        Task.start(fn -> EgressStitch.reconcile_device(device_id) end)
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
