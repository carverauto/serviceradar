defmodule ServiceRadar.TestSupport do
  @moduledoc """
  Test support utilities for ServiceRadar Core.

  In the single-deployment architecture, each deployment is single-deployment.
  The PostgreSQL search_path (set by CNPG credentials) determines the schema.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.ProcessRegistry

  @sandbox_teardown_margin_ms 60_000
  @sandbox_owner_attempts 3
  @sandbox_owner_retry_ms 100
  @dependency_dispatcher_drain_timeout_ms 30_000
  @dependency_dispatcher_registry_poll_ms 10
  @result_coordination_drain_timeout_ms 70_000
  @result_coordination_registry_poll_ms 10
  @stateful_engine_drain_timeout_ms 5_000
  @stateful_engine_registry_poll_ms 10
  @integration_runner_max_cases Map.new(
                                  [
                                    {{"async_serial", "async"}, 8},
                                    {{"large_ingestion", "large_ingestion"}, 1},
                                    {{"focused", "focused"}, 1}
                                  ] ++
                                    Enum.map(0..6, fn index ->
                                      {{"async_serial", "serial_#{index}"}, 1}
                                    end)
                                )
  @integration_runner_pool_sizes Map.new(@integration_runner_max_cases, fn
                                   {runner, _max_cases} -> {runner, 12}
                                 end)

  @doc "Starts core without implicitly taking database ownership."
  def start_core!(opts \\ []) do
    if Keyword.has_key?(opts, :synchronous_audit_writes?) do
      Application.put_env(
        :serviceradar_core,
        :audit_writer_async?,
        not Keyword.fetch!(opts, :synchronous_audit_writes?)
      )
    end

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
        owner = start_sandbox_owner!(ServiceRadar.Repo, owner_opts)

        ExUnit.Callbacks.on_exit(fn ->
          stop_repo_owner(owner, shared: shared?)
        end)

        configure_async_sandbox_transaction!(context)

        {:ok, sandbox_owner: owner}
    end
  end

  defp configure_async_sandbox_transaction!(%{async: true}) do
    ServiceRadar.Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")
    :ok
  end

  defp configure_async_sandbox_transaction!(_context), do: :ok

  @doc "Runs a serial test helper in a fresh shared rollback-only database owner."
  def with_repo_owner(context, fun) when is_function(fun, 0) do
    reject_async_shared_owner!(context)
    owner = start_sandbox_owner!(ServiceRadar.Repo, shared: true)

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
          "SQL sandbox allowance failed for test-owned child #{inspect(child_pid)}: #{inspect(result)}"
  end

  @doc "Validates ExUnit concurrency against the audited integration runner topology."
  def integration_max_cases!(value, topology, lane, profiling?) do
    count =
      case Integer.parse(value || "") do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> raise ArgumentError, "SERVICERADAR_INTEGRATION_MAX_CASES must be a positive integer"
      end

    if profiling? and count != 1 do
      raise ArgumentError, """
      SERVICERADAR_TEST_SLOWEST cannot be combined with concurrent integration execution;
      profiling requires max_cases=1, got #{count}
      """
    end

    expected_count =
      case {@integration_runner_max_cases[{topology, lane}], profiling?} do
        {configured_count, false} when is_integer(configured_count) -> configured_count
        {configured_count, true} when is_integer(configured_count) -> min(configured_count, 1)
        _ -> nil
      end

    if count == expected_count do
      count
    else
      raise ArgumentError, """
      unsupported integration runner configuration: topology=#{inspect(topology)} \
      lane=#{inspect(lane)} max_cases=#{count} profiling=#{inspect(profiling?)}
      """
    end
  end

  @doc "Validates the effective Repo pool against the capacity-audited runner topology."
  def integration_repo_pool_size!(pool_size, topology, lane) do
    expected_pool_size = @integration_runner_pool_sizes[{topology, lane}]

    if is_integer(pool_size) and pool_size == expected_pool_size do
      pool_size
    else
      raise ArgumentError, """
      unsupported integration Repo pool configuration: topology=#{inspect(topology)} \
      lane=#{inspect(lane)} pool_size=#{inspect(pool_size)} expected=#{inspect(expected_pool_size)}
      """
    end
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
    case supervisor_children(supervisor) do
      :supervisor_gone ->
        :ok

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

  # Both drains above check `Process.whereis/1` ONCE, then poll for up to a
  # minute with a sleep between iterations. `Task.Supervisor.children/1` is a
  # `GenServer.call`, so a supervisor that goes away inside that window exits the
  # caller with `:noproc` -- and these run from `on_exit`, so the exit lands on
  # the test rather than on the drain. That is what made
  # ServiceRadar.Edge.AgentCommandBusTest fail intermittently in the serial_5
  # integration lane:
  #
  #     ** (exit) exited in: GenServer.call(...ResultCoordinationTaskSupervisor,
  #                                         :which_children, :infinity)
  #         ** (EXIT) no process
  #
  # A supervisor that no longer exists has nothing left to drain, which is the
  # success condition -- so report it as one. Matching the `{GenServer, :call, _}`
  # shape keeps this to a failed call and lets any other exit through.
  defp supervisor_children(supervisor) do
    Task.Supervisor.children(supervisor)
  catch
    :exit, {_reason, {GenServer, :call, _args}} -> :supervisor_gone
  end

  defp await_empty_result_coordination(supervisor, deadline) do
    case supervisor_children(supervisor) do
      :supervisor_gone ->
        :ok

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

  # start_owner!/2 does `{:ok, pid} = Agent.start/1`. A pool :queue_timeout inside
  # Agent.init therefore becomes MatchError, not ConnectionError. The first serial
  # DataCase checkout can lose that race while Postgrex is still connecting after
  # the eight-lane fixture stampede; later tests in the same BEAM then pass.
  defp start_sandbox_owner!(repo, opts, attempts_left \\ @sandbox_owner_attempts) do
    Sandbox.start_owner!(repo, opts)
  rescue
    exception ->
      if attempts_left > 1 and sandbox_owner_queue_timeout?(exception) do
        Process.sleep(@sandbox_owner_retry_ms)
        start_sandbox_owner!(repo, opts, attempts_left - 1)
      else
        reraise exception, __STACKTRACE__
      end
  end

  @doc false
  def sandbox_owner_queue_timeout?(%MatchError{term: {:error, {exception, _stack}}}) do
    sandbox_owner_queue_timeout?(exception)
  end

  def sandbox_owner_queue_timeout?(%DBConnection.ConnectionError{reason: :queue_timeout}) do
    true
  end

  def sandbox_owner_queue_timeout?(_exception), do: false

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
