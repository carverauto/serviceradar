defmodule ServiceRadar.AgentConfig.ConfigInvalidatorTest do
  # Sync: these tests share the telemetry event name, and one registers the
  # production ConfigInvalidator name. Parallel cases would accept each other's
  # measurements.
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.ConfigInvalidator
  alias ServiceRadar.AgentConfig.ConfigServer

  test "scheduled scopes are unioned and a fleet invalidation dominates" do
    parent = self()
    attach(parent)

    {_pid, server} =
      start_invalidator(parent,
        push: fn type, scope -> send(parent, {:scope_pushed, type, scope}) end
      )

    ConfigInvalidator.request(server, :snmp, scope: {:device, "device-01"})
    ConfigInvalidator.request(server, :snmp, scope: ["agent-01", "agent-02"])
    ConfigInvalidator.request(server, :snmp, scope: ["agent-01"])
    fire_when_scheduled(server)
    expected = MapSet.new([{:device, "device-01"}, {:agent, "agent-01"}, {:agent, "agent-02"}])
    assert_receive {:scope_pushed, :snmp, ^expected}
    assert_receive {:telemetry, _, %{status: :ok}}

    ConfigInvalidator.request(server, :snmp, scope: ["agent-01"])
    ConfigInvalidator.request(server, :snmp)
    ConfigInvalidator.request(server, :snmp, scope: {:device, "device-02"})
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, :all_online}
    assert_receive {:telemetry, _, %{status: :ok}}
  end

  test "running invalidation preserves every pending scope and ignores stale timers" do
    parent = self()
    attach(parent)

    {_pid, server} =
      start_invalidator(parent,
        push: fn type, scope ->
          send(parent, {:scope_pushed, type, scope, self()})

          receive do
            :continue -> :ok
          end
        end
      )

    ConfigInvalidator.request(server, :snmp, scope: ["agent-01"])
    old_ref = fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, first, worker}
    assert first == MapSet.new([{:agent, "agent-01"}])
    ConfigInvalidator.request(server, :snmp, scope: {:device, "device-02"})
    ConfigInvalidator.request(server, :snmp, scope: ["agent-03"])
    _ = :sys.get_state(server)
    send(worker, :continue)
    assert_receive {:telemetry, _, %{status: :ok}}

    send(server, {:fire, :snmp, old_ref})
    _ = :sys.get_state(server)
    refute_received {:scope_pushed, :snmp, _, _}
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, pending, follow_worker}
    assert pending == MapSet.new([{:device, "device-02"}, {:agent, "agent-03"}])
    send(follow_worker, :continue)
    assert_receive {:telemetry, _, %{status: :ok}}
    refute_received {:timer, _}
  end

  test "failed worker retries its original scope together with pending owners" do
    parent = self()
    attach(parent)

    {_pid, server} =
      start_invalidator(parent,
        push: fn type, scope ->
          send(parent, {:scope_pushed, type, scope, self(), Process.get(:"$callers")})

          receive do
            :continue -> :ok
          end
        end
      )

    ConfigInvalidator.request(server, :snmp, scope: ["agent-01"])
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, _, worker, callers}
    assert parent in callers
    ConfigInvalidator.request(server, :snmp, scope: ["agent-02"])
    _ = :sys.get_state(server)
    Process.exit(worker, :kill)
    assert_receive {:telemetry, _, %{status: :killed}}
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, retry_scope, retry_worker, retry_callers}
    assert retry_scope == MapSet.new([{:agent, "agent-01"}, {:agent, "agent-02"}])
    assert parent in retry_callers
    send(retry_worker, :continue)
    assert_receive {:telemetry, _, %{status: :ok}}
    refute_received {:timer, _}
  end

  test "exhausted retries keep failed and pending owners in the follow-up" do
    parent = self()
    attach(parent)

    {_pid, server} =
      start_invalidator(parent,
        push: fn type, scope ->
          send(parent, {:scope_pushed, type, scope, self()})

          receive do
            :continue -> :ok
          end
        end
      )

    ConfigInvalidator.request(server, :snmp, scope: ["agent-01"])
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, _, first_worker}
    ConfigInvalidator.request(server, :snmp, scope: ["agent-02"])
    _ = :sys.get_state(server)
    Process.exit(first_worker, :kill)
    assert_receive {:telemetry, _, %{status: :killed}}
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, retry_scope, retry_worker}
    assert retry_scope == MapSet.new([{:agent, "agent-01"}, {:agent, "agent-02"}])
    ConfigInvalidator.request(server, :snmp, scope: ["agent-03"])
    _ = :sys.get_state(server)
    Process.exit(retry_worker, :kill)
    assert_receive {:telemetry, _, %{status: :killed}}
    fire_when_scheduled(server)
    assert_receive {:scope_pushed, :snmp, follow_scope, follow_worker}

    assert follow_scope ==
             MapSet.new([{:agent, "agent-01"}, {:agent, "agent-02"}, {:agent, "agent-03"}])

    send(follow_worker, :continue)
    assert_receive {:telemetry, _, %{status: :ok}}
    refute_received {:timer, _}
  end

  test "50 rapid snmp invalidates coalesce to one rebuild" do
    parent = self()
    attach(parent)
    {_pid, server} = start_invalidator(parent)

    for _ <- 1..50 do
      assert ConfigInvalidator.request(server, :snmp) == :ok
    end

    _ = :sys.get_state(server)
    assert_received {:timer, {:fire, :snmp, ref}}
    refute_received {:timer, _message}

    send(server, {:fire, :snmp, ref})

    assert_receive {:pushed, :snmp, 1}
    assert_receive {:telemetry, measurements, metadata}
    assert measurements.coalesced == 50
    assert measurements.duration >= 0
    assert measurements.worker_memory_bytes > 0
    assert metadata.config_type == :snmp
    assert metadata.status == :ok
    refute_receive {:pushed, _type, _generation}
  end

  test "an invalidate during a rebuild produces one follow-up with the final state" do
    parent = self()
    attach(parent)
    # Linked to the test process. ExUnit ends that process with :shutdown,
    # which stops the agent. A later Agent.stop in on_exit finds nothing.
    {:ok, generation} = Agent.start_link(fn -> 1 end)

    {_pid, server} =
      start_invalidator(parent,
        push: fn type, _scope ->
          value = Agent.get(generation, & &1)
          send(parent, {:pushed, type, value, self()})

          receive do
            :continue -> :ok
          end
        end
      )

    assert ConfigInvalidator.request(server, :snmp) == :ok
    ref = fire_when_scheduled(server)

    assert_receive {:pushed, :snmp, 1, worker}
    Agent.update(generation, fn _ -> 2 end)
    assert ConfigInvalidator.request(server, :snmp) == :ok
    _ = :sys.get_state(server)
    send(worker, :continue)

    assert_receive {:telemetry, first, %{status: :ok}}
    assert first.coalesced == 1
    follow_ref = fire_when_scheduled(server)
    refute follow_ref == ref

    assert_receive {:pushed, :snmp, 2, follow_worker}
    send(follow_worker, :continue)
    assert_receive {:telemetry, second, %{status: :ok}}
    assert second.coalesced == 1
    refute_receive {:pushed, _type, _generation, _worker}
    refute_receive {:telemetry, _measurements, _metadata}
  end

  test "a heap-killed rebuild leaves the invalidator alive and a later invalidate still pushes" do
    parent = self()
    attach(parent)
    # Same cleanup as the follow-up test: the link dies with the test process.
    {:ok, mode} = Agent.start_link(fn -> :boom end)

    {pid, server} =
      start_invalidator(parent,
        max_heap_words: 20_000,
        push: fn _type, _scope ->
          case Agent.get(mode, & &1) do
            :boom -> explode()
            :ok -> send(parent, :recovered)
          end
        end
      )

    assert ConfigInvalidator.request(server, :snmp) == :ok

    for _attempt <- 1..2 do
      _ref = fire_when_scheduled(server)
      assert_receive {:telemetry, measurements, %{status: :killed}}
      assert measurements.coalesced >= 1
      assert Process.alive?(pid)
    end

    refute_received {:timer, _message}
    assert Process.alive?(pid)

    Agent.update(mode, fn _ -> :ok end)
    assert ConfigInvalidator.request(server, :snmp) == :ok
    _ref = fire_when_scheduled(server)
    assert_receive :recovered
    assert_receive {:telemetry, _measurements, %{status: :ok}}
    assert Process.alive?(pid)
  end

  test "ConfigServer.invalidate accepts the cast before the push runs" do
    parent = self()
    Process.put(:serviceradar_config_invalidation_mode, :async)
    attach(parent)

    sup = Module.concat(__MODULE__, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {ConfigInvalidator,
       name: ConfigInvalidator,
       task_supervisor: sup,
       debounce_ms: 1_000,
       cache: fn _type -> :ok end,
       push: fn type, _scope -> send(parent, {:pushed, type, 1}) end,
       schedule: fn message, _delay ->
         send(parent, {:timer, message})
         make_ref()
       end}
    )

    assert ConfigServer.invalidate(:snmp) == :ok
    # The cast is async. get_state runs only after that cast is handled,
    # so the timer message is already in this mailbox.
    _ = :sys.get_state(ConfigInvalidator)
    refute_received {:pushed, :snmp, _generation}
    assert_received {:timer, {:fire, :snmp, _ref}}
  end

  defp fire_when_scheduled(server) do
    _ = :sys.get_state(server)
    assert_received {:timer, {:fire, :snmp, ref}}
    send(server, {:fire, :snmp, ref})
    ref
  end

  defp start_invalidator(parent, opts \\ []) do
    sup = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")
    name = Module.concat(__MODULE__, "Srv#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: sup})

    defaults = [
      name: name,
      task_supervisor: sup,
      debounce_ms: 1_000,
      cache: fn _type -> :ok end,
      push: fn type, _scope -> send(parent, {:pushed, type, 1}) end,
      schedule: fn message, _delay ->
        send(parent, {:timer, message})
        make_ref()
      end
    ]

    pid = start_supervised!({ConfigInvalidator, Keyword.merge(defaults, opts)})
    {pid, name}
  end

  defp attach(parent) do
    id = "config-invalidation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        ConfigInvalidator.telemetry_event(),
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(id)
    end)
  end

  defp explode(acc \\ [0]) do
    explode([acc | acc])
  end
end
