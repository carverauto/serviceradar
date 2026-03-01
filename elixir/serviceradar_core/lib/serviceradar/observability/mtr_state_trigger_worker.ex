defmodule ServiceRadar.Observability.MtrStateTriggerWorker do
  @moduledoc """
  Subscribes to health state transitions and dispatches incident/recovery MTR runs.
  """

  use GenServer

  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadar.Observability.{MtrAutomationDispatcher, MtrPolicy}

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, HealthPubSub.topic())
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:health_event, event}, state) do
    handle_health_event(event)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_health_event(event) do
    with {:ok, target_ctx} <- MtrAutomationDispatcher.target_ctx_from_health_event(event),
         transition when transition != :ignore <-
           MtrAutomationDispatcher.classify_transition(
             Map.get(event, :old_state),
             Map.get(event, :new_state)
           ) do
      dispatch_transition(target_ctx, transition)
    else
      :ignore -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp dispatch_transition(target_ctx, {mode, transition_class}) do
    incident_correlation_id =
      if mode == :incident do
        Ecto.UUID.generate()
      else
        nil
      end

    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        Enum.each(
          policies,
          &dispatch_policy(&1, target_ctx, mode, incident_correlation_id, transition_class)
        )

      {:ok, %Ash.Page.Keyset{results: policies}} ->
        Enum.each(
          policies,
          &dispatch_policy(&1, target_ctx, mode, incident_correlation_id, transition_class)
        )

      {:error, reason} ->
        Logger.warning("MTR trigger worker failed to load policies", reason: inspect(reason))
    end
  end

  defp dispatch_policy(policy, target_ctx, mode, incident_correlation_id, transition_class) do
    if mode == :recovery and Map.get(policy, :recovery_capture) != true do
      :ok
    else
      target_ctx = merge_policy_partition(target_ctx, policy)

      case MtrAutomationDispatcher.dispatch_for_mode(
             target_ctx,
             policy,
             mode,
             incident_correlation_id,
             transition_class: transition_class
           ) do
        {:ok, _selected_agents} ->
          :ok

        {:error, :cooldown_active} ->
          :ok

        {:error, :no_candidates} ->
          :ok

        {:error, reason} ->
          Logger.debug("MTR state-trigger dispatch skipped",
            mode: Atom.to_string(mode),
            policy: Map.get(policy, :name),
            target_key: Map.get(target_ctx, :target_key),
            reason: inspect(reason)
          )
      end
    end
  end

  defp merge_policy_partition(target_ctx, policy) do
    case Map.get(policy, :partition_id) do
      partition when is_binary(partition) and partition != "" ->
        Map.put(target_ctx, :partition_id, partition)

      _ ->
        target_ctx
    end
  end
end
