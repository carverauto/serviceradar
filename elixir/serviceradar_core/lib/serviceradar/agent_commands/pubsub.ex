defmodule ServiceRadar.AgentCommands.PubSub do
  @moduledoc """
  PubSub broadcaster for agent command acknowledgments, progress, and results.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.
  """

  @pubsub ServiceRadar.PubSub

  @doc "Build the agent command topic."
  def topic do
    "agent:commands"
  end

  @doc "Subscribe to all agent command updates."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  def broadcast_ack(data) when is_map(data) do
    safe_broadcast(topic(), {:command_ack, Map.put(data, :received_at, DateTime.utc_now())})
  end

  def broadcast_progress(data) when is_map(data) do
    safe_broadcast(topic(), {:command_progress, Map.put(data, :updated_at, DateTime.utc_now())})
  end

  def broadcast_result(data) when is_map(data) do
    safe_broadcast(topic(), {:command_result, Map.put(data, :completed_at, DateTime.utc_now())})
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
