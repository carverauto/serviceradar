defmodule ServiceRadar.Observability.ServiceStatusPubSub do
  @moduledoc """
  PubSub broadcaster for service status updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:service_status` - Service status updates

  ## Events

  - `{:service_status_updated, status}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:service_status"

  @doc """
  Returns the service status topic.
  """
  def topic, do: @topic

  @doc """
  Subscribe to service status updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcast a status update event.
  """
  def broadcast_update(status) do
    safe_broadcast(@topic, {:service_status_updated, status})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
