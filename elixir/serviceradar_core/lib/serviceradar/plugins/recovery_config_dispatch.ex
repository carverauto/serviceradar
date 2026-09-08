defmodule ServiceRadar.Plugins.RecoveryConfigDispatch do
  @moduledoc false

  # Recovery paths perform their assignment writes inside a raw outer Ecto
  # transaction so an identity change can roll every write back together. Ash
  # notifications remain unsent in that shape, therefore the committed path
  # uses the same exact-principal, version-aware config push directly.

  alias ServiceRadar.Edge.AgentCommandBus

  require Logger

  @task_supervisor ServiceRadar.AgentConfig.DependencyDispatcher.TaskSupervisor

  @doc """
  Schedules a version-aware config push for one already-authenticated edge
  principal.

  Call this only after the transaction that materialized the assignment has
  committed. The dispatcher receives `{partition_id, agent_uid}` rather than
  resolving a UID again, so a later identity change cannot redirect the push
  to a different partition.
  """
  @spec dispatch_after_commit(String.t(), String.t(), keyword()) :: :ok
  def dispatch_after_commit(agent_uid, partition_id, opts \\ [])

  def dispatch_after_commit(agent_uid, partition_id, opts)
      when is_binary(agent_uid) and is_binary(partition_id) do
    agent_uid = String.trim(agent_uid)
    partition_id = String.trim(partition_id)

    if agent_uid == "" or partition_id == "" do
      :ok
    else
      dispatcher = Keyword.get(opts, :config_dispatcher, &AgentCommandBus.push_config/2)

      case Keyword.get(opts, :config_dispatch_async?, true) do
        false ->
          invoke(dispatcher, partition_id, agent_uid)

        _ ->
          schedule(dispatcher, partition_id, agent_uid)
      end
    end
  end

  def dispatch_after_commit(_agent_uid, _partition_id, _opts), do: :ok

  defp schedule(dispatcher, partition_id, agent_uid) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           invoke(dispatcher, partition_id, agent_uid)
         end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp invoke(dispatcher, partition_id, agent_uid) do
    case dispatcher.(partition_id, agent_uid) do
      :ok ->
        :ok

      {:error, _reason} ->
        log_deferred_push(agent_uid, partition_id)

      _other ->
        log_deferred_push(agent_uid, partition_id)
    end

    :ok
  rescue
    _exception ->
      log_deferred_push(agent_uid, partition_id)
      :ok
  catch
    :exit, _reason ->
      log_deferred_push(agent_uid, partition_id)
      :ok
  end

  defp log_deferred_push(agent_uid, partition_id) do
    # Do not log a dispatcher error value: config-generation failures may carry
    # provider detail. The normal version-aware config path will retry on the
    # next reconciliation/poll.
    Logger.debug("recovery config push deferred",
      agent_uid: agent_uid,
      partition_id: partition_id
    )
  end
end
