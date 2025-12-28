defmodule ServiceRadar.Infrastructure.Changes.PublishStateChange do
  @moduledoc """
  Ash change that publishes state transition events to NATS JetStream.

  This change captures the old state before a transition and publishes
  an event after the transition completes successfully.

  ## Usage

  Add to any state machine transition action:

      update :go_offline do
        change transition_state(:offline)
        change {PublishStateChange, entity_type: :poller, new_state: :offline}
      end

  ## Options

  - `:entity_type` - The type of entity (required: :poller, :agent, :checker)
  - `:new_state` - The target state of the transition (required)
  - `:reason` - Optional reason for the transition (defaults to action name)
  """

  use Ash.Resource.Change

  alias ServiceRadar.Infrastructure.EventPublisher

  require Logger

  @impl true
  def init(opts) do
    entity_type = Keyword.fetch!(opts, :entity_type)
    new_state = Keyword.fetch!(opts, :new_state)

    unless entity_type in [:poller, :agent, :checker, :collector] do
      raise ArgumentError, "entity_type must be one of :poller, :agent, :checker, :collector"
    end

    {:ok, %{entity_type: entity_type, new_state: new_state}}
  end

  @impl true
  def change(changeset, opts, context) do
    # Capture the old state before the transition
    old_state = Ash.Changeset.get_data(changeset, :status)

    # Add after_action hook to publish the event
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      publish_event(record, old_state, opts, context)
      {:ok, record}
    end)
  end

  defp publish_event(record, old_state, opts, context) do
    new_state = opts.new_state
    entity_type = opts.entity_type

    # Don't publish if state didn't actually change
    if old_state == new_state do
      :ok
    else
      entity_id = get_entity_id(record, entity_type)
      _tenant_id = Map.get(record, :tenant_id)
      partition_id = Map.get(record, :partition_id)

      # Get reason from context or action name
      reason = get_reason(context)

      # Publish asynchronously to not block the transaction
      Task.start(fn ->
        case EventPublisher.on_state_transition(record, old_state, new_state, %{
               reason: reason,
               partition_id: partition_id
             }) do
          :ok ->
            Logger.debug(
              "Published #{entity_type} state change: #{entity_id} #{old_state} -> #{new_state}"
            )

          {:error, reason} ->
            Logger.warning(
              "Failed to publish #{entity_type} state change for #{entity_id}: #{inspect(reason)}"
            )
        end
      end)

      :ok
    end
  end

  defp get_entity_id(record, :poller), do: record.id
  defp get_entity_id(record, :agent), do: record.uid
  defp get_entity_id(record, :checker), do: to_string(record.id)
  defp get_entity_id(record, _), do: to_string(Map.get(record, :id))

  defp get_reason(%{action: %{name: action_name}}) when is_atom(action_name) do
    action_name
  end

  defp get_reason(_), do: :unknown
end
