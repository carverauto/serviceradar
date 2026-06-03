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

  @doc "Build the topic for updates belonging to one command."
  def topic(command_id) when is_binary(command_id) do
    "#{topic()}:#{command_id}"
  end

  @doc "Subscribe to all agent command updates."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  @doc "Subscribe to updates for one command."
  def subscribe(command_id) when is_binary(command_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(command_id))
  end

  def broadcast_ack(data) when is_map(data) do
    safe_broadcast(topic(), {:command_ack, Map.put(data, :received_at, DateTime.utc_now())})
  end

  def broadcast_progress(data) when is_map(data) do
    safe_broadcast(topic(), {:command_progress, Map.put(data, :updated_at, DateTime.utc_now())})
  end

  def broadcast_result(data) when is_map(data) do
    event = {:command_result, Map.put(data, :completed_at, DateTime.utc_now())}

    safe_broadcast(topic(), event)
    broadcast_command_scoped_result(data, event)
  end

  defp broadcast_command_scoped_result(data, event) do
    data
    |> command_scoped_topics()
    |> Enum.each(&safe_broadcast(&1, event))
  end

  defp command_scoped_topics(data) do
    [
      command_topic(data),
      response_subject_topic(data)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp command_topic(data) do
    case Map.get(data, :command_id) || Map.get(data, "command_id") do
      command_id when is_binary(command_id) and command_id != "" -> topic(command_id)
      _ -> nil
    end
  end

  defp response_subject_topic(data) do
    subject = Map.get(data, :response_subject) || Map.get(data, "response_subject")

    if valid_response_subject?(subject), do: subject
  end

  defp valid_response_subject?(subject) when is_binary(subject) do
    String.starts_with?(subject, "#{topic()}:")
  end

  defp valid_response_subject?(_subject), do: false

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
