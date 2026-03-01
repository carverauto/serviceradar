defmodule ServiceRadar.Inventory.DeviceNotifier do
  @moduledoc """
  Ash notifier for inventory device lifecycle events.
  """

  use Ash.Notifier

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DevicePubSub

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: Device,
        action: %{type: :create},
        data: record
      }) do
    DevicePubSub.broadcast_created(record)
    :ok
  end

  def notify(%Ash.Notifier.Notification{
        resource: Device,
        action: %{type: :update},
        data: record
      }) do
    DevicePubSub.broadcast_updated(record)
    :ok
  end

  def notify(%Ash.Notifier.Notification{
        resource: Device,
        action: %{type: :destroy},
        data: record
      }) do
    DevicePubSub.broadcast_deleted(record)
    :ok
  end

  def notify(_notification), do: :ok
end
