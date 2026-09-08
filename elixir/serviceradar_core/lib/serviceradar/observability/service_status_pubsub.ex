defmodule ServiceRadar.Observability.ServiceStatusPubSub do
  @moduledoc """
  PubSub broadcaster for service status updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:service_status` - Service status updates

  ## Events

  - `{:service_status_updated, status}`
  - `{:service_statuses_updated, [status]}` (batched flush)
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

  @doc """
  Broadcast a batch of status updates as a single event.

  Emits one `{:service_statuses_updated, statuses}` message for the whole flush
  instead of one `{:service_status_updated, status}` per item. `broadcast_update/1`
  is retained for callers that update a single status.
  """
  def broadcast_batch([]), do: :ok

  def broadcast_batch(statuses) when is_list(statuses) do
    safe_broadcast(@topic, {:service_statuses_updated, statuses})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
