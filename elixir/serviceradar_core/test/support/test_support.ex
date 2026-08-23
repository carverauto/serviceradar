defmodule ServiceRadar.TestSupport do
  @moduledoc """
  Test support utilities for ServiceRadar Core.

  In the single-deployment architecture, each deployment is single-deployment.
  The PostgreSQL search_path (set by CNPG credentials) determines the schema.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.ProcessRegistry

  @sandbox_teardown_margin_ms 60_000
  @dependency_dispatcher_drain_timeout_ms 30_000
  @dependency_dispatcher_registry_poll_ms 10
  @result_coordination_drain_timeout_ms 70_000
  @result_coordination_registry_poll_ms 10
  @stateful_engine_drain_timeout_ms 5_000
  @stateful_engine_registry_poll_ms 10

  @doc "Starts core without implicitly taking database ownership."
  def start_core!(opts \\ []) do
    Application.put_env(
      :serviceradar_core,
      :audit_writer_async?,
      not Keyword.get(opts, :synchronous_audit_writes?, true)
    )

    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    ensure_repo_started!()

    if sandbox_mode = Keyword.get(opts, :sandbox_mode) do
      Sandbox.mode(ServiceRadar.Repo, sandbox_mode)
    end

    if Keyword.get(opts, :sandbox_owner?, false) do
      checkout_repo!()
    end

    :ok
  end

  @doc "Checks out a rollback-only database owner for the current test."
  def checkout_repo!(context \\ %{}) do
    reject_async_unboxed!(context)

    cond do
      is_nil(Process.whereis(ServiceRadar.Repo)) ->
        :ok

      context[:sandbox] == :unboxed ->
        Sandbox.mode(ServiceRadar.Repo, :auto)

        ExUnit.Callbacks.on_exit(fn ->
          Sandbox.mode(ServiceRadar.Repo, :manual)
        end)

        :ok

      true ->
        shared? = not context[:async]
        owner_opts = sandbox_owner_opts(context)
        owner = Sandbox.start_owner!(ServiceRadar.Repo, owner_opts)

        ExUnit.Callbacks.on_exit(fn ->
          stop_repo_owner(owner, shared: shared?)
        end)

        {:ok, sandbox_owner: owner}
    end
  end

  @doc "Runs a serial test helper in a fresh shared rollback-only database owner."
  def with_repo_owner(context, fun) when is_function(fun, 0) do
    reject_async_shared_owner!(context)
    owner = Sandbox.start_owner!(ServiceRadar.Repo, shared: true)

    try do
      fun.()
    after
      stop_repo_owner(owner, shared: true)
    end
  end

  @doc false
  def stop_repo_owner(owner, shared: false) do
    if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    :ok
  end

  def stop_repo_owner(owner, shared: true) do
    drain_stateful_alert_engines()
    drain_dependency_dispatcher_tasks()
    drain_result_coordination_tasks()

    if Process.alive?(owner) do
      Sandbox.stop_owner(owner)
    end
  after
    # start_owner!/2 leaves the pool pointing at the stopped shared owner.
    Sandbox.mode(ServiceRadar.Repo, :manual)
  end

  @doc "Allows a test-owned child to use the caller's SQL Sandbox transaction."
  def allow_sandbox(child_pid) when is_pid(child_pid) do
    ServiceRadar.Repo
    |> Sandbox.allow(self(), child_pid)
    |> validate_sandbox_allowance!(child_pid)
  end

  @doc false
  def validate_sandbox_allowance!(result, _child_pid) when result in [:ok, {:already, :allowed}],
    do: :ok

  def validate_sandbox_allowance!(result, child_pid) do
    raise ArgumentError,
          "could not allow test-owned child #{inspect(child_pid)} in the SQL sandbox: #{inspect(result)}"
  end

  @doc false
  def drain_dependency_dispatcher_tasks do
    supervisor = ServiceRadar.AgentConfig.DependencyDispatcher.TaskSupervisor

    if Process.whereis(supervisor) do
      deadline =
        System.monotonic_time(:millisecond) + @dependency_dispatcher_drain_timeout_ms

      await_empty_dependency_dispatcher(supervisor, deadline)
    else
      :ok
    end
  end

  defp await_empty_dependency_dispatcher(supervisor, deadline) do
    case Task.Supervisor.children(supervisor) do
      [] ->
        :ok

      children ->
        if remaining_timeout(deadline) == 0 do
          raise "agent config dependency dispatcher did not drain: #{inspect(children)}"
        end

        receive do
        after
          min(@dependency_dispatcher_registry_poll_ms, remaining_timeout(deadline)) -> :ok
        end

        await_empty_dependency_dispatcher(supervisor, deadline)
    end
  end

  @doc false
  def drain_result_coordination_tasks do
    supervisor = ServiceRadar.AgentCommands.ResultCoordinationTaskSupervisor

    if Process.whereis(supervisor) do
      deadline = System.monotonic_time(:millisecond) + @result_coordination_drain_timeout_ms
      await_empty_result_coordination(supervisor, deadline)
    else
      :ok
    end
  end

  defp await_empty_result_coordination(supervisor, deadline) do
    case Task.Supervisor.children(supervisor) do
      [] ->
        :ok

      children ->
        if remaining_timeout(deadline) == 0 do
          raise "agent command result coordination did not drain: #{inspect(children)}"
        end

        receive do
        after
          min(@result_coordination_registry_poll_ms, remaining_timeout(deadline)) -> :ok
        end

        await_empty_result_coordination(supervisor, deadline)
    end
  end

  @doc false
  def drain_stateful_alert_engines do
    if Process.whereis(ProcessRegistry.registry_name()) do
      deadline =
        System.monotonic_time(:millisecond) + @stateful_engine_drain_timeout_ms

      do_drain_stateful_alert_engines(deadline)
    else
      :ok
    end
  end

  defp do_drain_stateful_alert_engines(deadline) do
    case stateful_alert_engine_entries() do
      [] ->
        :ok

      entries ->
        entries
        |> Enum.map(fn {_key, pid, _metadata} -> pid end)
        |> Enum.filter(&Process.alive?/1)
        |> Enum.uniq()
        |> Enum.each(&terminate_stateful_alert_engine(&1, deadline))

        await_empty_stateful_alert_registry(deadline)
    end
  end

  defp await_empty_stateful_alert_registry(deadline) do
    case stateful_alert_engine_entries() do
      [] ->
        :ok

      entries ->
        if remaining_timeout(deadline) == 0 do
          raise "stateful alert engine registry did not drain: #{inspect(entries)}"
        end

        case Enum.find(entries, fn {_key, pid, _metadata} -> Process.alive?(pid) end) do
          {_key, _pid, _metadata} ->
            do_drain_stateful_alert_engines(deadline)

          nil ->
            receive do
            after
              min(@stateful_engine_registry_poll_ms, remaining_timeout(deadline)) -> :ok
            end

            await_empty_stateful_alert_registry(deadline)
        end
    end
  end

  defp stateful_alert_engine_entries do
    Enum.filter(ProcessRegistry.select_all(), fn
      {:stateful_alert_engine, _pid, _metadata} -> true
      {{:stateful_alert_engine, _shard}, _pid, _metadata} -> true
      _other -> false
    end)
  end

  defp terminate_stateful_alert_engine(pid, deadline) do
    monitor_ref = Process.monitor(pid)

    try do
      case ProcessRegistry.terminate_child(pid) do
        :ok ->
          :ok

        {:error, :not_found} ->
          if Process.alive?(pid) do
            raise "stateful alert engine is alive but missing from its supervisor: #{inspect(pid)}"
          end

        {:error, reason} ->
          raise "failed to terminate stateful alert engine: #{inspect(reason)}"
      end

      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
      after
        remaining_timeout(deadline) ->
          raise "stateful alert engine did not terminate: #{inspect(pid)}"
      end
    after
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp sandbox_owner_opts(context) do
    opts = [shared: not context[:async]]

    case sandbox_ownership_timeout(context) do
      nil -> opts
      timeout -> Keyword.put(opts, :ownership_timeout, timeout)
    end
  end

  defp reject_async_unboxed!(%{async: true, sandbox: :unboxed}) do
    raise ArgumentError,
          "async tests cannot use unboxed sandbox mode; move this test to the serial lane"
  end

  defp reject_async_unboxed!(_context), do: :ok

  defp reject_async_shared_owner!(%{async: true}) do
    raise ArgumentError, "a shared owner cannot be started from an async test context"
  end

  defp reject_async_shared_owner!(_context), do: :ok

  @doc false
  def sandbox_ownership_timeout(context) do
    case context[:timeout] do
      timeout when is_integer(timeout) and timeout > 120_000 ->
        timeout + @sandbox_teardown_margin_ms

      _other ->
        nil
    end
  end

  defp ensure_repo_started! do
    repo_enabled? = Application.get_env(:serviceradar_core, :repo_enabled, true) != false

    if repo_enabled? and is_nil(Process.whereis(ServiceRadar.Repo)) do
      case ServiceRadar.Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end
end
