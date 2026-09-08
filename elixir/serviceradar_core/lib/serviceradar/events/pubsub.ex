defmodule ServiceRadar.Events.PubSub do
  @moduledoc """
  PubSub broadcaster for OCSF event updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `serviceradar:events` - OCSF event updates

  ## Events

  - `{:ocsf_event, %ServiceRadar.Monitoring.OcsfEvent{}}`
  """

  @pubsub ServiceRadar.PubSub
  @events_topic "serviceradar:events"

  @doc """
  Returns the OCSF events topic.
  """
  def topic, do: @events_topic

  @doc """
  Broadcast an OCSF event to the events topic.
  """
  def broadcast_event(event) when is_map(event) do
    safe_broadcast(@events_topic, {:ocsf_event, event})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
