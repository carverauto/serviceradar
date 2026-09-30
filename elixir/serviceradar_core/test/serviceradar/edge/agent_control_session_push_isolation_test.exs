defmodule ServiceRadar.Edge.AgentControlSessionPushIsolationTest do
  @moduledoc """
  Regression for issue #4816: a config push broadcast from one async test's
  sandbox must not target another test's registered agent control session.

  `AgentCommandBus.push_config_for_type/1` pushes to every online session in
  the app-wide `ProcessRegistry`. Async tests share that registry and the
  app-wide `ConfigCache` but each own an isolated SQL sandbox, so an
  unfiltered broadcast from one test compiled another test's agent config
  inside the pushing test's sandbox and cached those fragments app-wide under
  the owning test's agent key — which the owning test then read back as its
  own compiled config.

  The concurrent "other async test" here is a separate owner process that
  registers its own control session through the canonical test-support helper
  (stamping `test_owner` with its pid), exactly as a concurrent test process
  does; the pushing side runs in this test's process with this test's sandbox.
  The `:snmp` push only targets sessions carrying the `snmp` capability — the
  same targeting `ConfigServer.invalidate(:snmp)` performs in production — so
  the broadcast reaches the stubs registered below and no other test's
  session, keeping this test's pushes from contaminating anyone else.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @partition_id "default"
  @stub_capabilities ["snmp"]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "config pushes skip a control session owned by another test's sandbox" do
    unique = System.unique_integer([:positive])
    actor = SystemActor.system(:agent_control_push_isolation_test)

    # Another async test's session: a separate owner process registers it for
    # an agent that also exists in this sandbox's database view, so a push
    # from here would compile this sandbox's fragments and cache them under
    # that agent's key if the session were not filtered out.
    foreign_agent = "push-isolation-foreign-#{unique}"
    {:ok, _agent} = create_connected_agent(foreign_agent, actor)
    foreign_owner = start_control_session_stub!(foreign_agent, marked: true)

    assert :ok = AgentCommandBus.push_config_for_type(:snmp)

    # The foreign session was skipped: no fragment was compiled under its
    # agent's key, and its owner process saw no push on the control stream.
    assert [] = snmp_cache_entries_for(foreign_agent)
    refute control_session_stub_pushed?(foreign_owner)

    # Production dispatch is unchanged: an unmarked session, registered the
    # way the gateway registers real control sessions (no test owner in the
    # metadata), is still a broadcast target and still receives the push.
    production_agent = "push-isolation-production-#{unique}"
    {:ok, _agent} = create_connected_agent(production_agent, actor)

    production_session = start_control_session_stub!(production_agent, marked: false)

    assert :ok = AgentCommandBus.push_config_for_type(:snmp)

    # The stub answered a real {:push_config, response} call, which the
    # command bus only places after compiling and caching that agent's config
    # — production dispatch is unchanged. (The cached entry itself is not
    # asserted: any concurrent test may invalidate the :snmp cache type.)
    assert control_session_stub_pushed?(production_session)

    stop_control_session_stub(foreign_owner)
    stop_control_session_stub(production_session)
  end

  # The app-wide cache the push writes into, keyed by
  # {config_type, partition, agent_id, scope}. The snmp compiler scopes entries
  # per agent, so assert on any snmp entry under the agent rather than one
  # exact scope.
  defp snmp_cache_entries_for(agent_uid) do
    :agent_config_cache
    |> :ets.tab2list()
    |> Enum.filter(fn
      {{:snmp, _partition, cached_agent, _scope}, _entry, _expires_at} ->
        cached_agent == agent_uid

      _other ->
        false
    end)
  end

  defp create_connected_agent(agent_uid, actor) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Push Isolation Agent #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create()
  end

  # A stand-in for a control-stream session owner. It registers a session in
  # the app-wide registry — through the canonical test helper (marked with its
  # owning pid) or the way the gateway registers production sessions — and
  # answers `{:push_config, response}` the way `ControlStreamSession` does,
  # recording whether a push ever arrived.
  defp start_control_session_stub!(agent_uid, marked: marked?) do
    parent = self()

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        register_stub_session!(agent_uid, marked?)

        send(parent, {:stub_ready, self()})
        control_session_stub_loop(parent, false)
      end)

    assert_receive {:stub_ready, ^pid}, 5_000
    await_session_evidence!(agent_uid)
    pid
  end

  defp register_stub_session!(agent_uid, true) do
    TestSupport.register_agent_control_session!(agent_uid, @partition_id,
      capabilities: @stub_capabilities
    )
  end

  defp register_stub_session!(agent_uid, false) do
    {:ok, _pid} =
      ProcessRegistry.register(
        {:agent_control, @partition_id, agent_uid, node()},
        %{
          agent_id: agent_uid,
          partition_id: @partition_id,
          gateway_node: node(),
          capabilities: @stub_capabilities
        }
      )

    :ok
  end

  defp control_session_stub_loop(parent, pushed?) do
    receive do
      {:"$gen_call", {from, ref}, {:push_config, _response}} ->
        send(from, {ref, :ok})
        control_session_stub_loop(parent, true)

      {:probe_pushed, from} ->
        send(from, {:pushed, pushed?})
        control_session_stub_loop(parent, pushed?)

      :stop ->
        :ok

      {:EXIT, ^parent, _reason} ->
        :ok
    end
  end

  defp control_session_stub_pushed?(stub_pid) do
    ref = Process.monitor(stub_pid)
    send(stub_pid, {:probe_pushed, self()})

    receive do
      {:pushed, pushed?} ->
        Process.demonitor(ref, [:flush])
        pushed?

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("control session stub exited before probing: #{inspect(reason)}")
    after
      5_000 -> flunk("control session stub did not answer the probe")
    end
  end

  defp stop_control_session_stub(stub_pid) do
    ref = Process.monitor(stub_pid)
    send(stub_pid, :stop)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(stub_pid, :kill)
        :ok
    end
  end

  defp await_session_evidence!(agent_uid, attempts \\ 40)

  defp await_session_evidence!(_agent_uid, 0),
    do: flunk("test control-session partition did not converge")

  defp await_session_evidence!(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(@partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: @partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_session_evidence!(agent_uid, attempts - 1)
    end
  end
end
