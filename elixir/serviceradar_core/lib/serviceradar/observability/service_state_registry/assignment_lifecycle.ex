defmodule ServiceRadar.Observability.ServiceStateRegistry.AssignmentLifecycle do
  @moduledoc false

  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
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

    with {:ok, package} <- load_package(assignment, actor),
         {:ok, agent} <- Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      identity =
        StatusNormalizer.identity_from_agent(
          agent,
          package.name,
          "plugin",
          assignment.agent_uid
        )

      PluginState.deactivate_logical_states(identity, actor)
    else
      {:error, reason} ->
        Logger.warning("Failed to resolve service identity for assignment: #{inspect(reason)}")
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
    case Agent.get_by_uid(assignment.agent_uid, actor: actor) do
      {:ok, agent} ->
        identity =
          StatusNormalizer.identity_from_agent(
            agent,
            package.name,
            "plugin",
            assignment.agent_uid
          )

        PluginState.deactivate_logical_states(identity, actor)

      {:error, reason} ->
        Logger.warning("Failed to resolve agent for assignment: #{inspect(reason)}")
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
        Enum.each(rows, fn [agent_id, partition, service_type, service_name] ->
          PluginState.deactivate_logical_states(
            %{
              agent_id: agent_id,
              partition: partition,
              service_type: service_type,
              service_name: service_name
            },
            actor
          )
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to load orphaned package service states: #{inspect(reason)}")
        :ok
    end
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
    case load_existing_logical_state(attrs, actor) do
      {:ok, %ServiceState{state: "active"} = state} ->
        if StatusNormalizer.assignment_placeholder_state?(state) do
          upsert_assignment_state_with_notifications(attrs, actor)
        else
          {:ok, [], []}
        end

      {:ok, nil} ->
        upsert_assignment_state_with_notifications(attrs, actor)

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

  defp load_existing_logical_state(attrs, actor) do
    ServiceState
    |> filter(
      agent_id == ^Map.fetch!(attrs, :agent_id) and
        partition == ^Map.fetch!(attrs, :partition) and
        service_type == ^Map.fetch!(attrs, :service_type) and
        service_name == ^Map.fetch!(attrs, :service_name) and
        state == "active"
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} ->
        {:ok, Enum.max_by(states, &StatusNormalizer.logical_state_rank/1, fn -> nil end)}

      error ->
        error
    end
  end

  defp load_package(%PluginAssignment{} = assignment, actor) do
    PluginPackage
    |> Ash.Query.filter(id == ^assignment.plugin_package_id)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Plugins)
  end
end
