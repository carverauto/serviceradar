defmodule ServiceRadar.Infrastructure.Changes.PublishStateChange do
  @moduledoc """
  Ash change that publishes state transition events to NATS JetStream
  and records health events for history tracking.

  This change captures the old state before a transition and:
  1. Publishes an event to NATS JetStream for real-time notifications
  2. Records a HealthEvent for historical tracking and UI display

  ## Usage

  Add to any state machine transition action:

      update :go_offline do
        change transition_state(:offline)
        change {PublishStateChange, entity_type: :gateway, new_state: :offline}
      end

  ## Options

  - `:entity_type` - The type of entity (required: :gateway, :agent, :checker)
  - `:new_state` - The target state of the transition (required)
  - `:reason` - Optional reason for the transition (defaults to action name)
  """

  use Ash.Resource.Change

  alias ServiceRadar.Infrastructure.HealthTracker

  require Logger

  @impl true
  def init(opts) do
    entity_type = Keyword.fetch!(opts, :entity_type)
    new_state = Keyword.fetch!(opts, :new_state)

    unless entity_type in [:gateway, :agent, :checker, :collector] do
      raise ArgumentError, "entity_type must be one of :gateway, :agent, :checker, :collector"
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

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp publish_event(record, old_state, opts, context) do
    new_state = opts.new_state
    entity_type = opts.entity_type

    # Don't publish if state didn't actually change
    if old_state == new_state do
      :ok
    else
      entity_id = get_entity_id(record, entity_type)
      tenant_id = Map.get(record, :tenant_id)
      metadata = get_entity_metadata(record, entity_type)

      # Get reason from context or action name
      reason = get_reason(context)

      # Use HealthTracker to record event and publish to NATS
      HealthTracker.record_state_change(entity_type, entity_id, tenant_id,
        old_state: old_state,
        new_state: new_state,
        reason: reason,
        metadata: metadata
      )

      :ok
    end
  end

  defp get_entity_id(record, :gateway), do: record.id
  defp get_entity_id(record, :agent), do: record.uid
  defp get_entity_id(record, :checker), do: to_string(record.id)
  defp get_entity_id(record, _), do: to_string(Map.get(record, :id))

  # Get entity-specific metadata fields
  defp get_entity_metadata(record, :gateway), do: %{partition_id: Map.get(record, :partition_id)}
  defp get_entity_metadata(record, :agent), do: %{gateway_id: Map.get(record, :gateway_id)}
  defp get_entity_metadata(record, :checker), do: %{agent_uid: Map.get(record, :agent_uid)}
  defp get_entity_metadata(_record, _), do: %{}

  defp get_reason(%{action: %{name: action_name}}) when is_atom(action_name) do
    action_name
  end

  defp get_reason(_), do: :unknown
end
