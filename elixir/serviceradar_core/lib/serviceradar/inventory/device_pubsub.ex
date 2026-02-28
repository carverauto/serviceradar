defmodule ServiceRadar.Inventory.DevicePubSub do
  @moduledoc """
  PubSub broadcaster for inventory device lifecycle events.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:inventory:devices"

  @doc """
  Returns the devices topic.
  """
  def topic, do: @topic

  @doc """
  Subscribe to device lifecycle updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcast that a device was created.
  """
  def broadcast_created(%{uid: uid} = device) when is_binary(uid) do
    safe_broadcast(@topic, {:device_created, uid, device})
  end

  def broadcast_created(_), do: :ok

  @doc """
  Broadcast that a device was updated.
  """
  def broadcast_updated(%{uid: uid} = device) when is_binary(uid) do
    safe_broadcast(@topic, {:device_updated, uid, device})
  end

  def broadcast_updated(_), do: :ok

  @doc """
  Broadcast that a device was deleted.
  """
  def broadcast_deleted(%{uid: uid}) when is_binary(uid) do
    safe_broadcast(@topic, {:device_deleted, uid})
  end

  def broadcast_deleted(_), do: :ok

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
