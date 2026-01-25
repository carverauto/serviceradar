defmodule ServiceRadar.Observability.ServiceStatePubSub do
  @moduledoc """
  PubSub broadcaster for service state updates.

  ## Topics

  - `serviceradar:service_state` - Service state updates

  ## Events

  - `{:service_state_updated, state}`
  """

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:service_state"

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def broadcast_update(state) do
    safe_broadcast(@topic, {:service_state_updated, state})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
