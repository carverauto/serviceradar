defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginState do
  @moduledoc false

  import Ash.Query

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Repo

  require Logger

  @streaming_plugin_capability "camera_media_stream"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @plugin_result_output "serviceradar.plugin_result.v1"
  @plugin_state_lock_namespace "plugin-service-state"
  @plugin_state_reconcile_lock "plugin-service-state-reconcile"

  @doc false
  @spec acquire_lock(map()) :: :ok | {:error, term()}
  def acquire_lock(identity) when is_map(identity) do
    lock_identity =
      identity
      |> StatusNormalizer.logical_plugin_identity()
      |> then(fn identity ->
        Jason.encode!([
          @plugin_state_lock_namespace,
          identity.agent_id,
          identity.partition,
          identity.service_type,
          identity.service_name
        ])
      end)

    with :ok <- acquire_reconcile_shared_lock() do
      case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_identity]) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:plugin_state_lock_acquire_failed, reason}}
        other -> {:error, {:unexpected_plugin_state_lock_result, other}}
      end
    end
  end

  def acquire_lock(_identity), do: {:error, :invalid_plugin_state_identity}

  @doc false
  def acquire_reconciliation_lock do
    case Repo.query(Queries.lock_plugin_state_reconciliation(), []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_state_lock_result, other}}
    end
  end

  defp acquire_reconcile_shared_lock do
    case Repo.query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [
           @plugin_state_reconcile_lock
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:plugin_state_reconcile_lock_acquire_failed, reason}}
      other -> {:error, {:unexpected_plugin_state_reconcile_lock_result, other}}
    end
  end

  @doc false
  def prepare_upsert_side_effects(
        %ServiceState{service_type: "plugin", state: "inactive"} = state,
        _previous,
        actor,
        upserted?
      ) do
    identity = StatusNormalizer.logical_plugin_identity(state)

    with {:ok, active_states} <- active_logical_plugin_states(identity, actor),
         {:ok, notifications, changed_states} <-
           deactivate_states_with_notifications(active_states, actor) do
      side_effects = Enum.map(changed_states, &{:broadcast_update, &1})

      side_effects =
        if upserted? do
          side_effects ++ [{:broadcast_update, state}]
        else
          side_effects
        end

      {:ok, notifications, side_effects}
    end
  end

  def prepare_upsert_side_effects(
        %ServiceState{service_type: "plugin"} = state,
        previous,
        actor,
        upserted?
      ) do
    with {:ok, notifications, changed_states, winner} <-
           reconcile_logical_plugin_states_with_notifications(state, actor) do
      side_effects = Enum.map(changed_states, &{:broadcast_update, &1})

      side_effects =
        if upserted? and winner.id == state.id do
          side_effects ++ [{:state_upserted, winner, previous}]
        else
          side_effects
        end

      {:ok, notifications, side_effects}
    end
  end

  def prepare_upsert_side_effects(state, previous, _actor, true) do
    {:ok, [], [{:state_upserted, state, previous}]}
  end

  def prepare_upsert_side_effects(_state, _previous, _actor, false), do: {:ok, [], []}

  @doc false
  def deactivate_logical_states(identity, actor) when is_map(identity) do
    deactivate_logical_states(identity, actor, fn states -> {:ok, states} end)
  end

  @doc false
  def deactivate_logical_states(identity, actor, select_states)
      when is_map(identity) and is_function(select_states, 1) do
    identity = StatusNormalizer.logical_plugin_identity(identity)

    case Repo.transaction(fn ->
           with :ok <- acquire_lock(identity),
                {:ok, states} <- active_logical_plugin_states(identity, actor),
                {:ok, selected_states} <- select_states.(states),
                {:ok, notifications, updated_states} <-
                  deactivate_states_with_notifications(selected_states, actor) do
             {notifications, updated_states}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {notifications, updated_states}} ->
        _ = Ash.Notifier.notify(notifications)
        Enum.each(updated_states, &ServiceStatePubSub.broadcast_update/1)
        :ok

      {:error, error} ->
        Logger.warning("Failed to deactivate logical plugin state: #{inspect(error)}")
        :ok

      other ->
        Logger.warning("Unexpected logical plugin state deactivate result: #{inspect(other)}")
        :ok
    end
  end

  @doc false
  def prepare_snapshot_reactivation(%ServiceState{} = winner, states, actor)
      when is_list(states) do
    with {:ok, notifications, changed_states} <-
           apply_logical_plugin_state_winner(states, winner, actor) do
      {:ok, notifications, Enum.map(changed_states, &{:broadcast_update, &1})}
    end
  end

  @doc false
  def deactivate_shadowed(%ServiceState{service_type: "plugin"} = current_state, actor) do
    ServiceState
    |> filter(
      id != ^current_state.id and
        agent_id == ^current_state.agent_id and
        partition == ^current_state.partition and
        service_type == ^current_state.service_type and
        service_name == ^current_state.service_name and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} ->
        Enum.each(states, &deactivate_shadow_state(&1, actor))

      {:error, error} ->
        Logger.warning("Failed to load shadowed plugin states: #{inspect(error)}")
    end
  end

  def deactivate_shadowed(_state, _actor), do: :ok

  @doc false
  def deactivate_inactive_count do
    # These bulk cleanup passes intentionally skip PubSub. They reconcile reload-time
    # Postgres state and avoid broadcasting one message per stale row. Keep both
    # passes atomic so a failed orphan pass cannot expose a reactivated orphan.
    case Repo.transaction(fn ->
           with :ok <- acquire_reconciliation_lock(),
                {:ok, shadow_count} <- reconcile_plugin_state_winners(),
                {:ok, orphan_count} <- deactivate_orphaned_active_plugin_states() do
             shadow_count + orphan_count
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_state_cleanup_result, other}}
    end
  end

  defp active_logical_plugin_states(identity, actor) do
    ServiceState
    |> filter(
      agent_id == ^identity.agent_id and
        partition == ^identity.partition and
        service_type == ^identity.service_type and
        service_name == ^identity.service_name and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
  end

  defp deactivate_states_with_notifications(states, actor) when is_list(states) do
    Enum.reduce_while(states, {:ok, [], []}, fn state, {:ok, notifications, updated_states} ->
      state
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
      |> Ash.update(domain: ServiceRadar.Observability, return_notifications?: true)
      |> case do
        {:ok, updated, state_notifications} ->
          {:cont, {:ok, notifications ++ state_notifications, updated_states ++ [updated]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp reconcile_logical_plugin_states_with_notifications(
         %ServiceState{service_type: "plugin"} = current_state,
         actor
       ) do
    with {:ok, states} <- logical_plugin_states(current_state, actor),
         %ServiceState{} = winner <- logical_plugin_state_winner(states),
         {:ok, notifications, changed_states} <-
           apply_logical_plugin_state_winner(states, winner, actor) do
      winner = Enum.find(changed_states, winner, &(&1.id == winner.id))
      {:ok, notifications, changed_states, winner}
    else
      nil -> {:error, :logical_plugin_state_winner_missing}
      {:error, _reason} = error -> error
    end
  end

  defp logical_plugin_states(%ServiceState{} = state, actor) do
    ServiceState
    |> filter(
      agent_id == ^state.agent_id and
        partition == ^state.partition and
        service_type == ^state.service_type and
        service_name == ^state.service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
  end

  defp logical_plugin_state_winner([]), do: nil

  defp logical_plugin_state_winner(states) do
    Enum.max_by(states, &StatusNormalizer.logical_state_rank/1)
  end

  defp apply_logical_plugin_state_winner(states, winner, actor) do
    # Avoid exposing two active rows when repair needs to reactivate the winner.
    states
    |> Enum.sort_by(&(&1.id == winner.id))
    |> Enum.reduce_while({:ok, [], []}, fn state, {:ok, notifications, changed_states} ->
      desired_state = if state.id == winner.id, do: "active", else: "inactive"

      if state.state == desired_state do
        {:cont, {:ok, notifications, changed_states}}
      else
        action = if desired_state == "active", do: :activate, else: :deactivate

        state
        |> Ash.Changeset.for_update(action, %{}, actor: actor)
        |> Ash.update(domain: ServiceRadar.Observability, return_notifications?: true)
        |> case do
          {:ok, updated, state_notifications} ->
            {:cont, {:ok, notifications ++ state_notifications, changed_states ++ [updated]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    end)
  end

  defp deactivate_shadow_state(%ServiceState{} = state, actor) do
    state
    |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
    |> Ash.update(domain: ServiceRadar.Observability)
    |> case do
      {:ok, updated} ->
        ServiceStatePubSub.broadcast_update(updated)

      {:error, error} ->
        Logger.warning("Failed to deactivate shadowed plugin state: #{inspect(error)}")
    end
  end

  defp reconcile_plugin_state_winners do
    params = [@streaming_plugin_output, @plugin_result_output, @streaming_plugin_capability]

    case Repo.query(Queries.reconcile_plugin_state_winners(), params) do
      {:ok, %{rows: [[count]]}} ->
        {:ok, normalize_count(count)}

      {:ok, _result} ->
        {:ok, 0}

      {:error, reason} = error ->
        Logger.warning("Failed to reconcile plugin service state winners: #{inspect(reason)}")
        error
    end
  end

  defp deactivate_orphaned_active_plugin_states do
    params = [
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(Queries.deactivate_orphaned_active_plugin_states(), params) do
      {:ok, %{rows: [[count]]}} ->
        {:ok, normalize_count(count)}

      {:ok, _result} ->
        {:ok, 0}

      {:error, reason} = error ->
        Logger.warning("Failed to deactivate orphaned plugin service states: #{inspect(reason)}")
        error
    end
  end

  defp normalize_count(count) when is_integer(count), do: count

  defp normalize_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp normalize_count(_count), do: 0
end
