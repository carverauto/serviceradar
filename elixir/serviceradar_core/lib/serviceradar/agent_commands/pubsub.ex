defmodule ServiceRadar.AgentCommands.PubSub do
  @moduledoc """
  PubSub broadcaster for agent command acknowledgments, progress, and results.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.
  """

  @pubsub ServiceRadar.PubSub
  @ingress_topic "agent:commands:ingress"

  @doc "Build the agent command topic."
  def topic do
    "agent:commands"
  end

  @doc "Build the private ingress topic consumed by the persistence gate."
  def ingress_topic, do: @ingress_topic

  @doc "Topic for agent release target status changes."
  def release_target_topic do
    "agent:release_targets"
  end

  @doc "Subscribe to agent release target status changes."
  def subscribe_release_targets do
    Phoenix.PubSub.subscribe(@pubsub, release_target_topic())
  end

  @doc """
  Broadcast that an agent release target changed status.

  Emitted on every persisted target status transition (including reconciler
  driven terminal transitions that never flow through a command result), so
  subscribers such as the releases LiveView can refresh their view of
  `agent_release_targets` without a manual reload.
  """
  def broadcast_release_target_status(data) when is_map(data) do
    safe_broadcast(release_target_topic(), {:release_target_status, data})
  end

  @doc "Build the topic for updates belonging to one command."
  def topic(command_id) when is_binary(command_id) do
    "#{topic()}:#{command_id}"
  end

  @doc "Subscribe to all agent command updates."
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  @doc "Subscribe to unaudited gateway updates before durable persistence."
  def subscribe_ingress do
    Phoenix.PubSub.subscribe(@pubsub, ingress_topic())
  end

  @doc "Subscribe to updates for one command."
  def subscribe(command_id) when is_binary(command_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(command_id))
  end

  def broadcast_ack(data) when is_map(data) do
    safe_broadcast(
      ingress_topic(),
      {:command_ack, Map.put(data, :received_at, DateTime.utc_now())}
    )
  end

  def broadcast_progress(data) when is_map(data) do
    safe_broadcast(
      ingress_topic(),
      {:command_progress, Map.put(data, :updated_at, DateTime.utc_now())}
    )
  end

  def broadcast_result(data) when is_map(data) do
    event = {:command_result, Map.put(data, :completed_at, DateTime.utc_now())}

    safe_broadcast(ingress_topic(), event)
  end

  @doc "Publish one completed sweep fanout decision to command-status subscribers."
  def broadcast_sweep_dispatch(data) when is_map(data) do
    safe_broadcast(topic(), {:sweep_dispatch, data})
  end

  @doc "Publish an acknowledgment only after the status handler persisted it exactly."
  def broadcast_persisted_ack(data) when is_map(data) do
    event = {:command_ack, Map.put_new(data, :received_at, DateTime.utc_now())}

    safe_broadcast(topic(), event)
  end

  @doc "Publish progress only after the status handler persisted it exactly."
  def broadcast_persisted_progress(data) when is_map(data) do
    event = {:command_progress, Map.put_new(data, :updated_at, DateTime.utc_now())}

    safe_broadcast(topic(), event)
  end

  @doc "Fan out a command result only after the status handler persisted it exactly."
  def broadcast_persisted_result(data) when is_map(data) do
    event = {:command_result, Map.put_new(data, :completed_at, DateTime.utc_now())}

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
