defmodule ServiceRadar.Observability.MtrStateTriggerWorker do
  @moduledoc """
  Subscribes to health state transitions and dispatches incident/recovery MTR runs.
  """

  use GenServer

  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPolicy

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
      end

    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        policies
        |> Enum.reduce(init_dispatch_stats(), fn policy, acc ->
          update_dispatch_stats(
            acc,
            dispatch_policy(policy, target_ctx, mode, incident_correlation_id, transition_class)
          )
        end)
        |> log_dispatch_summary(mode, transition_class, Map.get(target_ctx, :target_key))

      {:ok, %Ash.Page.Keyset{results: policies}} ->
        policies
        |> Enum.reduce(init_dispatch_stats(), fn policy, acc ->
          update_dispatch_stats(
            acc,
            dispatch_policy(policy, target_ctx, mode, incident_correlation_id, transition_class)
          )
        end)
        |> log_dispatch_summary(mode, transition_class, Map.get(target_ctx, :target_key))

      {:error, reason} ->
        Logger.warning("MTR trigger worker failed to load policies", reason: inspect(reason))
    end
  end

  defp dispatch_policy(policy, target_ctx, mode, incident_correlation_id, transition_class) do
    if mode == :recovery and Map.get(policy, :recovery_capture) != true do
      :recovery_disabled
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
          :dispatched

        {:error, :cooldown_active} ->
          :cooldown

        {:error, :no_candidates} ->
          :no_candidates

        {:error, reason} ->
          {:failed, dispatch_reason_key(reason)}
      end
    end
  end

  defp init_dispatch_stats do
    %{
      dispatched: 0,
      cooldown: 0,
      no_candidates: 0,
      recovery_disabled: 0,
      failed: 0,
      reasons: %{}
    }
  end

  defp update_dispatch_stats(stats, :dispatched), do: Map.update!(stats, :dispatched, &(&1 + 1))
  defp update_dispatch_stats(stats, :cooldown), do: Map.update!(stats, :cooldown, &(&1 + 1))

  defp update_dispatch_stats(stats, :no_candidates),
    do: Map.update!(stats, :no_candidates, &(&1 + 1))

  defp update_dispatch_stats(stats, :recovery_disabled),
    do: Map.update!(stats, :recovery_disabled, &(&1 + 1))

  defp update_dispatch_stats(stats, {:failed, reason_key}) do
    stats
    |> Map.update!(:failed, &(&1 + 1))
    |> Map.update!(:reasons, fn reasons -> Map.update(reasons, reason_key, 1, &(&1 + 1)) end)
  end

  defp dispatch_reason_key(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp dispatch_reason_key({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp dispatch_reason_key(reason), do: inspect(reason)

  defp log_dispatch_summary(stats, mode, transition_class, target_key) do
    Logger.info(
      "MTR trigger dispatch summary " <>
        "mode=#{mode} transition_class=#{transition_class} target_key=#{target_key} " <>
        "dispatched=#{stats.dispatched} cooldown=#{stats.cooldown} " <>
        "no_candidates=#{stats.no_candidates} recovery_disabled=#{stats.recovery_disabled} " <>
        "failed=#{stats.failed} reasons=#{format_reason_counts(stats.reasons)}"
    )
  end

  defp format_reason_counts(reasons) when map_size(reasons) == 0, do: "none"

  defp format_reason_counts(reasons) do
    reasons
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Enum.map_join(",", fn {key, count} -> "#{key}:#{count}" end)
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
