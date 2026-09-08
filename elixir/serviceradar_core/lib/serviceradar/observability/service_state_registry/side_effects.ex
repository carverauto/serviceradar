defmodule ServiceRadar.Observability.ServiceStateRegistry.SideEffects do
  @moduledoc false

  alias ServiceRadar.EventWriter.StateChangePublisher
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub

  @doc false
  @spec dispatch(list()) :: :ok | {:error, term()}
  def dispatch(side_effects) when is_list(side_effects) do
    Enum.each(side_effects, fn
      {:broadcast_update, state} ->
        ServiceStatePubSub.broadcast_update(state)

      {:state_upserted, state, previous} ->
        ServiceStatePubSub.broadcast_update(state)
        publish_transition(previous, state)
    end)

    :ok
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def publish_transition(previous, %ServiceState{} = state) do
    old_available = previous && Map.get(previous, :available)
    new_available = state.available

    if not is_nil(previous) and old_available != new_available do
      StateChangePublisher.publish_transition(
        "service_state",
        service_state_entity_uid(state),
        field: "available",
        old: old_available,
        new: new_available,
        partition_id: state.partition,
        entity_type: "service",
        extra: %{
          "agent_id" => state.agent_id,
          "gateway_id" => state.gateway_id,
          "service_type" => state.service_type,
          "service_name" => state.service_name
        }
      )
    else
      :ok
    end
  end

  def publish_transition(_previous, _state), do: :ok

  # Composite service identity (Decision 2): service_state has no device uid, so
  # the engine keys service transitions by this composite and resolves the owning
  # device from agent_id when needed.
  defp service_state_entity_uid(%ServiceState{} = state) do
    "#{state.agent_id}:#{state.service_type}:#{state.service_name}"
  end
end
