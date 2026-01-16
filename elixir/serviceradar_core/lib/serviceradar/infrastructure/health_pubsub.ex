defmodule ServiceRadar.Infrastructure.HealthPubSub do
  @moduledoc """
  PubSub broadcaster for internal health state events.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:health_events` - Health event updates

  ## Events

  - `{:health_event, %ServiceRadar.Infrastructure.HealthEvent{}}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:health_events"

  @doc """
  Returns the health events topic.
  """
  def topic, do: @topic

  @doc """
  Broadcast a HealthEvent to the health events topic.
  """
  def broadcast_health_event(event) do
    safe_broadcast(@topic, {:health_event, event})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
