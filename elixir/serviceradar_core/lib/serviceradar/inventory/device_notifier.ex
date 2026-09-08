defmodule ServiceRadar.Inventory.DeviceNotifier do
  @moduledoc """
  Ash notifier for inventory device lifecycle events.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DevicePubSub

  @impl Ash.Notifier
  def notify(%Notification{resource: Device, action: %{type: :create}, data: record}) do
    invalidate_identity_cache(record)
    DevicePubSub.broadcast_created(record)
    :ok
  end

  def notify(%Notification{
        resource: Device,
        action: %{type: :update},
        data: record,
        changeset: changeset
      }) do
    invalidate_identity_cache(changeset_data(changeset))
    invalidate_identity_cache(record)
    DevicePubSub.broadcast_updated(record)
    :ok
  end

  def notify(%Notification{resource: Device, action: %{type: :destroy}, data: record}) do
    invalidate_identity_cache(record)
    DevicePubSub.broadcast_deleted(record)
    :ok
  end

  def notify(_notification), do: :ok

  defp changeset_data(%{data: data}), do: data
  defp changeset_data(_), do: nil

  defp invalidate_identity_cache(%{ip: ip}) when is_binary(ip) and ip != "" do
    IdentityCache.delete(ip)
  end

  defp invalidate_identity_cache(_record), do: :ok
end
