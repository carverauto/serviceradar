defmodule ServiceRadar.Inventory.WebPropertyNotifier do
  @moduledoc """
  Ash notifier for `ServiceRadar.Inventory.WebProperty`.

  Emits post-commit PubSub notifications for UI updates and M4.2 RUM policy sync
  without forcing actions non-atomic.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Inventory.WebPropertyPubSub

  @impl true
  def notify(%Notification{action: %{name: :create}, data: data}) do
    WebPropertyPubSub.broadcast_created(data)
    :ok
  end

  def notify(%Notification{action: %{name: :rotate_rum_site_key}, data: data}) do
    WebPropertyPubSub.broadcast_rum_key_rotated(data)
    :ok
  end

  def notify(%Notification{action: %{name: :update}, data: data}) do
    WebPropertyPubSub.broadcast_updated(data)
    :ok
  end

  def notify(%Notification{action: %{name: :update_posture}, data: data}) do
    WebPropertyPubSub.broadcast_updated(data)
    :ok
  end

  def notify(%Notification{action: %{name: :destroy}, data: data}) do
    WebPropertyPubSub.broadcast_deleted(data)
    :ok
  end

  def notify(_notification), do: :ok
end
