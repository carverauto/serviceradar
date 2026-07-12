defmodule ServiceRadar.Observability.ServiceStateRegistry.AssignmentLifecycle do
  @moduledoc false

  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries
  alias ServiceRadar.Observability.ServiceStateRegistry.SideEffects
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusIngestor
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  require Logger

  @streaming_plugin_capability "camera_media_stream"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @plugin_result_output "serviceradar.plugin_result.v1"

  @doc false
  @spec upsert(PluginAssignment.t()) :: :ok
  def upsert(%PluginAssignment{} = assignment) do
    actor = SystemActor.system(:service_state_registry)

    with {:ok, package} <- load_package(assignment, actor),
         true <- StatusNormalizer.should_track_assignment_service?(assignment, package),
         {:ok, agent} <- Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      assignment
      |> StatusNormalizer.build_attrs_from_assignment(agent, package)
      |> maybe_upsert_assignment_state(actor)
    else
      false ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to resolve assignment service identity: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Assignment service state upsert failed: #{Exception.message(error)}")
      :ok
  end

  def upsert(_), do: :ok

  @doc false
  @spec reconcile(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:service_state_registry))

    PluginAssignment
    |> filter(enabled == true)
    |> Ash.read(actor: actor, domain: ServiceRadar.Plugins)
    |> case do
      {:ok, assignments} ->
        Enum.each(assignments, &upsert/1)

        case PluginState.deactivate_inactive_count() do
          {:ok, inactive_count} -> {:ok, length(assignments) + inactive_count}
          {:error, _reason} = error -> error
        end

      {:error, reason} = error ->
        Logger.warning("Failed to reconcile plugin assignment service states: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning(
        "Plugin assignment service state reconciliation failed: #{Exception.message(error)}"
      )

      {:error, error}
  end

  @doc false
  @spec deactivate_assignment(PluginAssignment.t()) :: :ok
  def deactivate_assignment(%PluginAssignment{} = assignment) do
    actor = SystemActor.system(:service_state_registry)

    case load_package(assignment, actor) do
      {:ok, %PluginPackage{} = package} ->
        deactivate_package_states_for_agent(assignment.agent_uid, package, assignment.id, actor)

      {:error, reason} ->
        Logger.warning("Failed to resolve service identity for assignment: #{inspect(reason)}")
        :ok

      other ->
        Logger.warning("Unexpected service identity for assignment: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Service state deactivate failed: #{Exception.message(error)}")
      :ok
  end

  def deactivate_assignment(_), do: :ok

  @doc false
  @spec deactivate_package(PluginPackage.t()) :: :ok
  def deactivate_package(%PluginPackage{} = package) do
    actor = SystemActor.system(:service_state_registry)

    PluginAssignment
    |> filter(plugin_package_id == ^package.id)
    |> Ash.read(actor: actor, domain: ServiceRadar.Plugins)
    |> case do
      {:ok, assignments} ->
        Enum.each(assignments, fn assignment ->
          deactivate_assignment_with_package(assignment, package, actor)
        end)

        deactivate_orphaned_package_states(package, actor)

      {:error, reason} ->
        Logger.warning("Failed to load plugin assignments: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Service state package deactivate failed: #{Exception.message(error)}")
      :ok
  end

  def deactivate_package(_), do: :ok

  defp deactivate_assignment_with_package(%PluginAssignment{} = assignment, package, actor) do
    deactivate_package_states_for_agent(assignment.agent_uid, package, assignment.id, actor)
  end

  defp deactivate_package_states_for_agent(
         agent_uid,
         %PluginPackage{} = package,
         assignment_id,
         actor
       ) do
    params = [
      agent_uid,
      package.name,
      package.plugin_id,
      assignment_id,
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(Queries.package_state_identities_for_agent(), params) do
      {:ok, %{rows: rows}} ->
        deactivate_identity_rows(rows, package, assignment_id, actor)

      {:error, reason} ->
        Logger.warning(
          "Failed to load package service states for agent #{agent_uid}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp deactivate_orphaned_package_states(%PluginPackage{} = package, actor) do
    params = [
      package.name,
      package.plugin_id,
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(Queries.orphaned_package_state_identities(), params) do
      {:ok, %{rows: rows}} ->
        deactivate_identity_rows(rows, package, nil, actor)

      {:error, reason} ->
        Logger.warning("Failed to load orphaned package service states: #{inspect(reason)}")
        :ok
    end
  end

  defp deactivate_identity_rows(rows, package, excluded_assignment_id, actor)
       when is_list(rows) do
    Enum.each(rows, fn [agent_id, partition, service_type, service_name] ->
      PluginState.deactivate_logical_states(
        %{
          agent_id: agent_id,
          partition: partition,
          service_type: service_type,
          service_name: service_name
        },
        actor,
        &select_deactivation_states(&1, package, excluded_assignment_id)
      )
    end)

    :ok
  end

  defp maybe_upsert_assignment_state(attrs, actor) do
    case Repo.transaction(fn ->
           with :ok <- PluginState.acquire_lock(attrs),
                {:ok, notifications, side_effects} <-
                  prepare_assignment_state_upsert(attrs, actor) do
             {notifications, side_effects}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {notifications, side_effects}} ->
        _ = Ash.Notifier.notify(notifications)

        case SideEffects.dispatch(side_effects) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Assignment service state side-effects failed: #{inspect(reason)}")
            :ok
        end

      {:error, error} ->
        Logger.warning("Assignment service state upsert failed: #{inspect(error)}")
        :ok

      other ->
        Logger.warning("Unexpected assignment service state upsert result: #{inspect(other)}")
        :ok
    end
  end

  defp prepare_assignment_state_upsert(attrs, actor) do
    case load_existing_logical_states(attrs, actor) do
      {:ok, logical_states} ->
        with {:ok, states} <- assignment_state_candidates(logical_states, attrs) do
          case states do
            :preserve_distinct_state ->
              {:ok, [], []}

            states ->
              winner =
                Enum.max_by(states, &StatusNormalizer.logical_state_rank/1, fn -> nil end)

              cond do
                is_nil(winner) ->
                  upsert_assignment_state_with_notifications(attrs, actor)

                StatusNormalizer.assignment_placeholder_state?(winner) ->
                  upsert_assignment_state_with_notifications(attrs, actor)

                winner.state == "active" ->
                  {:ok, [], []}

                true ->
                  PluginState.prepare_snapshot_reactivation(winner, states, actor)
              end
          end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp upsert_assignment_state_with_notifications(attrs, actor) do
    previous = StatusIngestor.previous_service_availability(attrs, actor)

    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
    |> Ash.create(
      domain: ServiceRadar.Observability,
      return_notifications?: true
    )
    |> case do
      {:ok, state, notifications} ->
        if StatusIngestor.upsert_skipped?(state) do
          {:ok, [], []}
        else
          with {:ok, side_effect_notifications, side_effects} <-
                 PluginState.prepare_upsert_side_effects(state, previous, actor, true) do
            {:ok, notifications ++ side_effect_notifications, side_effects}
          end
        end

      {:error, error} ->
        {:error, error}

      other ->
        {:error, {:unexpected_assignment_service_state_upsert_result, other}}
    end
  end

  defp load_existing_logical_states(attrs, actor) do
    package_name = Map.fetch!(attrs, :service_name)

    ServiceState
    |> filter(
      agent_id == ^Map.fetch!(attrs, :agent_id) and
        partition == ^Map.fetch!(attrs, :partition) and
        service_type == ^Map.fetch!(attrs, :service_type) and
        service_name == ^package_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
  end

  defp load_package(%PluginAssignment{} = assignment, actor) do
    PluginPackage
    |> Ash.Query.filter(id == ^assignment.plugin_package_id)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Plugins)
  end

  defp select_deactivation_states(states, package, excluded_assignment_id) do
    states
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, selected} ->
      if PluginStateContract.package_matches_state?(state, package.name, package.plugin_id) do
        case alternate_assignment_eligible?(state, excluded_assignment_id) do
          {:ok, true} -> {:cont, {:ok, selected}}
          {:ok, false} -> {:cont, {:ok, [state | selected]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, selected}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      {:error, _reason} = error -> error
    end
  end

  defp alternate_assignment_eligible?(state, excluded_assignment_id) do
    state_plugin_id = PluginStateContract.state_plugin_id(state)

    params = [
      state.agent_id,
      optional_uuid(excluded_assignment_id),
      state_plugin_id,
      state.service_name,
      @plugin_result_output,
      @streaming_plugin_output,
      @streaming_plugin_capability
    ]

    case Repo.query(alternate_assignment_eligible_sql(), params) do
      {:ok, %{rows: [[eligible?]]}} when is_boolean(eligible?) -> {:ok, eligible?}
      {:error, reason} -> {:error, {:assignment_eligibility_recheck_failed, reason}}
      other -> {:error, {:unexpected_assignment_eligibility_recheck_result, other}}
    end
  end

  defp alternate_assignment_eligible_sql do
    """
    SELECT EXISTS (
      SELECT 1
      FROM platform.plugin_assignments AS assignment
      JOIN platform.plugin_packages AS package
        ON package.id = assignment.plugin_package_id
      WHERE assignment.enabled = true
        AND package.status = 'approved'
        AND assignment.agent_uid = $1
        AND ($2::text IS NULL OR assignment.id <> ($2::text)::uuid)
        AND CASE
          WHEN NULLIF($3, '') IS NOT NULL THEN package.plugin_id = $3
          ELSE package.name = $4
        END
        AND (
          package.outputs IN ($5, $6)
          OR $7 = ANY(package.approved_capabilities)
          OR (
            coalesce(array_length(package.approved_capabilities, 1), 0) = 0
            AND package.manifest->'capabilities' ? $7
          )
        )
    )
    """
  end

  defp optional_uuid(nil), do: nil
  defp optional_uuid(id), do: to_string(id)

  defp assignment_state_candidates(logical_states, attrs) do
    package_name = Map.fetch!(attrs, :service_name)
    plugin_id = PluginStateContract.state_plugin_id(attrs)

    {matching, distinct} =
      Enum.split_with(
        logical_states,
        &PluginStateContract.package_matches_state?(&1, package_name, plugin_id)
      )

    case matching do
      [] ->
        case eligible_explicit_state?(distinct) do
          {:ok, true} -> {:ok, :preserve_distinct_state}
          {:ok, false} -> {:ok, []}
          {:error, _reason} = error -> error
        end

      matching ->
        {:ok, matching}
    end
  end

  defp eligible_explicit_state?(states) do
    Enum.reduce_while(states, {:ok, false}, fn state, {:ok, false} ->
      if PluginStateContract.state_plugin_id(state) do
        case alternate_assignment_eligible?(state, nil) do
          {:ok, true} -> {:halt, {:ok, true}}
          {:ok, false} -> {:cont, {:ok, false}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, false}}
      end
    end)
  end
end
