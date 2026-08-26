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
        owner = Sandbox.start_owner!(ServiceRadar.Repo, owner_opts)

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

  @doc """
  Fails when the test database has migrations applied that this checkout does not contain.

  ## Why this is not covered by `mix ecto.migrate`

  `sr_core_template` is a SHARED, CROSS-BRANCH resource, and it only ever ratchets FORWARD:
  whichever branch runs the lifecycle first leaves its schema behind for every branch that
  clones it afterwards. A branch that is BEHIND therefore runs its own code against a FUTURE
  schema -- and nothing in the existing lifecycle notices, because Ecto only ever asks
  "is anything PENDING?". A behind-branch's migrations are a strict SUBSET of what is applied,
  so the answer is no and `mix ecto.migrate` prints "Migrations already up".

  This is not hypothetical. On 2026-08-25, staging's
  `20260825030000_rekey_discovered_interfaces_current_state` rekeyed
  `discovered_interfaces` from `(timestamp, device_id, interface_uid)` to
  `(device_id, interface_uid)` and updated `Inventory.Interface`'s identity to match. Every
  branch cut before that kept the three-column identity, cloned staging's rekeyed template,
  and emitted `ON CONFLICT (timestamp, device_id, interface_uid)` against a table with no
  such constraint. The result was 15 opaque `42P10 invalid_column_reference` failures spread
  over four unrelated-looking test files in two shards, with no mention of a migration
  anywhere -- which is what this replaces with one line naming the extra versions.

  ## Direction matters

  Only EXTRA APPLIED versions are an error. Pending ones are the normal "you need to migrate"
  case that Ecto already reports well, and the lifecycle's migrate step exists to fix. Failing
  on those here would turn a routine first run into a hard stop.
  """
  def assert_migrations_not_ahead!(applied_versions, on_disk_versions)
      when is_list(applied_versions) and is_list(on_disk_versions) do
    # NOT VACUOUS: an empty on-disk list would make every applied version "extra" and produce a
    # confusing failure that blames the database for a staging bug, so it is its own error.
    if on_disk_versions == [] do
      raise ArgumentError, """
      no migration files were found on disk, so schema drift cannot be assessed.

      This is a packaging fault, not a database fault: the guard needs priv/repo/migrations
      staged as a runtime input to compare against.
      """
    end

    case Enum.sort(applied_versions -- on_disk_versions) do
      [] ->
        :ok

      extra ->
        raise ArgumentError, """
        the test database is AHEAD of this checkout: #{length(extra)} migration(s) are applied \
        that this branch does not contain.

        Extra applied versions: #{Enum.join(extra, ", ")}

        The shared sr_core_template only ratchets forward, so a branch behind staging clones a
        FUTURE schema and runs its own resources against it. `mix ecto.migrate` cannot see this
        -- it only reports PENDING migrations, and this branch has none.

        Merge or rebase onto the branch that added those migrations. Do NOT re-provision: a
        fresh clone of the same template reproduces it exactly.
        """
    end
  end

  @doc """
  Reads the applied and on-disk migration versions and hands them to
  `assert_migrations_not_ahead!/2`.

  Separate from the pure check so the comparison is testable without a database, and so a
  failure here is unambiguously about IO rather than about drift.
  """
  def assert_database_schema_not_ahead!(repo \\ ServiceRadar.Repo) do
    prefix =
      :serviceradar_core
      |> Application.get_env(repo, [])
      |> Keyword.get(:migration_default_prefix, "public")

    # The Repo is started in MANUAL sandbox mode, so a bare query here has no ownership and
    # fails with "cannot find ownership process". This runs before any test has checked a
    # connection out, which is exactly the case unboxed_run/2 exists for -- the same way Oban's
    # own verify_migrated!/1 reads its migration state at boot.
    %{rows: rows} =
      Sandbox.unboxed_run(repo, fn ->
        Ecto.Adapters.SQL.query!(repo, ~s(SELECT version FROM "#{prefix}".schema_migrations), [])
      end)

    applied = Enum.map(rows, fn [version] -> to_string(version) end)

    on_disk =
      :serviceradar_core
      |> Application.app_dir("priv/repo/migrations")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(&(&1 |> String.split("_", parts: 2) |> hd()))

    assert_migrations_not_ahead!(applied, on_disk)
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
