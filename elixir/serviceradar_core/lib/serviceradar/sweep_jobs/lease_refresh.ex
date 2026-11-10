defmodule ServiceRadar.SweepJobs.LeaseRefresh do
  @moduledoc """
  Runs one control session's sweep lease refresh on core, outside the RPC that asked for it.

  A refresh reissues the full window of every lease the agent holds
  (`ServiceRadar.SweepJobs.LeasePass.refresh_agent/3`): each unrun slot is signed again and its
  mapping evidence committed before the push. That work grows with the lease horizon, so it
  has no fixed duration and cannot run inside a call with a deadline. A caller that gives up
  does not stop the work, cannot tell that it succeeded, and asks again.

  `start/4` therefore returns as soon as the refresh runs under this module's task supervisor,
  and the outcome reaches the session as a message:

      {:sweep_lease_refresh_result, attempt, :ok | {:error, reason}}

  The returned pid is the refresh. The session monitors it, so a refresh that ends without a
  result (a crash, a core node going down) is seen and retried rather than waited on.

  The refresh belongs to the session that asked for it. When that session ends the refresh is
  stopped where it stands: its leases could only be sent to a session that no longer exists,
  and the agent's next session asks for its own. A refresh stopped part-way leaves at most a
  recorded push that was never sent, which the lease pass replaces because it is never
  acknowledged.
  """

  require Logger

  @task_supervisor __MODULE__.TaskSupervisor

  @type result :: :ok | {:error, term()}

  @doc "The child spec of the supervisor refreshes run under."
  @spec task_supervisor_child() :: {module(), keyword()}
  def task_supervisor_child, do: {Task.Supervisor, name: @task_supervisor}

  @doc """
  Starts `refresh` for `session` and returns its pid. `attempt` is the session's own counter
  and comes back on the result message, so the session can tell which attempt answered.
  """
  @spec start(String.t(), pid(), non_neg_integer(), (-> result())) ::
          {:ok, pid()} | {:error, term()}
  def start(agent_id, session, attempt, refresh)
      when is_binary(agent_id) and is_pid(session) and is_integer(attempt) and attempt >= 0 and
             is_function(refresh, 0) do
    work = fn -> run(agent_id, session, attempt, refresh) end

    case Task.Supervisor.start_child(@task_supervisor, work) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # The work runs in a task linked to this process, which waits for either its result or the
  # end of the session. Killing the task on the latter releases what it holds: the delivery
  # lock (`:global` drops a dead holder's locks) and any open transaction.
  defp run(agent_id, session, attempt, refresh) do
    session_ref = Process.monitor(session)
    started = System.monotonic_time(:millisecond)
    %Task{ref: task_ref} = task = Task.async(refresh)

    receive do
      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        log_finished(agent_id, result, System.monotonic_time(:millisecond) - started)
        send(session, {:sweep_lease_refresh_result, attempt, result})

      {:DOWN, ^session_ref, :process, _pid, _reason} ->
        Task.shutdown(task, :brutal_kill)

        Logger.info(
          "Sweep lease refresh stopped, its control session ended: agent_id=#{inspect(agent_id)} " <>
            "elapsed_ms=#{System.monotonic_time(:millisecond) - started}"
        )
    end
  end

  defp log_finished(agent_id, :ok, elapsed_ms) do
    Logger.info(
      "Sweep lease refresh finished: agent_id=#{inspect(agent_id)} elapsed_ms=#{elapsed_ms}"
    )
  end

  defp log_finished(agent_id, {:error, reason}, elapsed_ms) do
    Logger.warning(
      "Sweep lease refresh failed: agent_id=#{inspect(agent_id)} elapsed_ms=#{elapsed_ms} " <>
        "reason=#{inspect(reason)}"
    )
  end
end
