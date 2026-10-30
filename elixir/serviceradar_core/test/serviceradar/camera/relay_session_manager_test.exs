defmodule ServiceRadar.Camera.RelaySessionManagerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.AgentCommandCleanupWorker
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  @moduletag :integration
  @moduletag sandbox: :unboxed

  defmodule HoldingControlSession do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, opts[:test_pid]}

    @impl true
    def handle_call({:send_command, command, _context}, _from, test_pid) do
      send(test_pid, {:relay_command, command})
      {:noreply, test_pid}
    end
  end

  setup do: Fixtures.context()

  test "the dispatched command remains linked after the opener dies before receiving its reply",
       ctx do
    agent_id = "agent-relay-#{Ecto.UUID.generate()}"
    {:ok, _source} = Source.update_source(ctx.source, %{assigned_agent_id: agent_id}, ctx.opts)
    parent = self()

    assert {:ok, cleanup_job} = AgentCommandCleanupWorker.ensure_scheduled()

    if match?(%Oban.Job{conflict?: false}, cleanup_job) do
      on_exit(fn ->
        Repo.query!("DELETE FROM platform.oban_jobs WHERE id = $1", [cleanup_job.id])
      end)
    end

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.agent_commands WHERE agent_id = $1", [agent_id])

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM platform.agent_commands WHERE agent_id = $1", [
                 agent_id
               ])
    end)

    name =
      ProcessRegistry.via({:agent_control, "default", agent_id, node()}, %{
        agent_id: agent_id,
        partition_id: "default",
        gateway_node: ctx.source.assigned_gateway_id,
        pending_config_version: nil
      })

    session = start_supervised!({HoldingControlSession, name: name, test_pid: parent})
    assert wait_for_control_session("default", agent_id, session)

    dispatch = fn agent, payload, opts, _requester ->
      AgentCommandBus.start_camera_relay(
        agent,
        Map.put(payload, :source_url, "rtsp://host01.example.com/stream/main"),
        opts
      )
    end

    {opener, monitor} =
      spawn_monitor(fn ->
        result = Fixtures.open(ctx, dispatch_open: dispatch)
        send(parent, {:open_result, result})
      end)

    on_exit(fn ->
      if Process.alive?(opener), do: Process.exit(opener, :kill)
    end)

    assert_receive {:relay_command, %Monitoring.CommandRequest{} = command}, 5_000
    payload = Jason.decode!(command.payload_json)
    assert command.command_type == "camera.open_relay"
    assert [%{status: :opening} = reserved] = Fixtures.sessions(ctx)
    assert reserved.id == payload["relay_session_id"]
    assert reserved.command_id == command.command_id

    assert %{rows: [["camera.open_relay", ^agent_id, stored_payload]]} =
             Repo.query!(
               "SELECT command_type, agent_id, payload FROM platform.agent_commands " <>
                 "WHERE command_id = $1::text::uuid",
               [command.command_id]
             )

    assert stored_payload == payload

    Process.exit(opener, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^opener, :killed}
    refute_received {:open_result, _}

    assert {:ok, reused} = Fixtures.open(ctx, dispatch_open: dispatch)
    assert reused.id == reserved.id
    assert reused.command_id == command.command_id
    refute_received {:relay_command, _}
  end

  test "committed concurrent opens dispatch one pull and reuse its persisted opening reservation",
       ctx do
    parent = self()

    dispatch = fn _agent, payload, opts, _requester ->
      {:ok, persisted} = RelaySession.get_by_id(payload.relay_session_id, ctx.opts)
      assert persisted.status == :opening
      assert persisted.lease_token == payload.lease_token
      assert is_binary(persisted.command_id)
      assert persisted.command_id == opts[:command_id]
      send(parent, {:dispatched, payload.relay_session_id})
      {:ok, opts[:command_id]}
    end

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :open -> Fixtures.open(ctx, dispatch_open: dispatch)
          after
            5_000 -> flunk("open barrier not released")
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, :open))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %{status: :opening}}, &1))
    assert [id] = results |> Enum.map(fn {:ok, session} -> session.id end) |> Enum.uniq()
    assert_receive {:dispatched, ^id}
    refute_received {:dispatched, _}
    assert [%{id: ^id, command_id: command_id}] = Fixtures.sessions(ctx)
    assert is_binary(command_id)
    assert {:ok, %{relay_session_id: ^id, epoch: 1}} = IngestOwnership.for_relay(id, ctx.opts)
  end

  test "heals gateway assignment and keeps the authorized viewer as command requester", ctx do
    parent = self()
    user = %{id: Ecto.UUID.generate(), permissions: ["devices.view", "devices.cameras.view"]}
    supplied_id = Ecto.UUID.generate()

    dispatch = fn agent, payload, opts, requester ->
      send(parent, {:command, agent, payload, opts, requester})
      {:ok, opts[:command_id]}
    end

    assert {:ok, session} =
             Fixtures.open(ctx,
               scope: %{user: user, actor: user},
               command_id: supplied_id,
               insecure_skip_verify: true,
               control_gateway_resolver: fn _, _ -> {:ok, "gateway-replacement"} end,
               dispatch_open: dispatch
             )

    assert session.gateway_id == "gateway-replacement"
    assert session.requested_by == user.id

    assert {:ok, %{assigned_gateway_id: "gateway-replacement"}} =
             Source.get_by_id(ctx.source.id, ctx.opts)

    assert_receive {:command, "agent-example", payload, command_opts, ^user}
    assert payload.camera_source_id == ctx.source.id
    assert payload.stream_profile_id == ctx.profile.id
    assert payload.insecure_skip_verify
    assert byte_size(payload.lease_token) == 32
    assert command_opts[:required_gateway_node] == "gateway-replacement"
    assert command_opts[:command_id] == session.command_id
    assert command_opts[:command_id] != supplied_id

    assert {:error, :not_found} =
             Fixtures.open(ctx,
               scope: %{user: user, actor: nil},
               dispatch_open: fn _, _, _, _ -> flunk("anonymous scope dispatched a relay") end
             )
  end

  test "rejects missing assignment and unavailable agent control without creating a relay", ctx do
    assert {:error, :agent_unavailable} =
             Fixtures.open(ctx,
               control_gateway_resolver: fn _, _ -> {:error, :agent_unavailable} end
             )

    assert Fixtures.sessions(ctx) == []
    {:ok, _} = Source.update_source(ctx.source, %{assigned_agent_id: nil}, ctx.opts)
    assert {:error, "camera source is not assigned to an edge agent"} = Fixtures.open(ctx)
    assert Fixtures.sessions(ctx) == []
  end

  test "failed open dispatch retires its reservation and allows a new attempt", ctx do
    assert {:error, :delivery_failed} =
             Fixtures.open(ctx,
               dispatch_open: fn _, _, _, _ -> {:error, :delivery_failed} end
             )

    assert [%{status: :failed, failure_reason: ":delivery_failed"} = failed] =
             Fixtures.sessions(ctx)

    assert Fixtures.owner(ctx).state == :released
    assert {:ok, replacement} = Fixtures.open(ctx)
    assert replacement.id != failed.id
    assert Fixtures.owner(ctx).epoch == 2
  end

  test "a mismatched dispatch reply cannot replace the reserved command identity", ctx do
    other_id = Ecto.UUID.generate()

    assert {:error, :relay_command_id_mismatch} =
             Fixtures.open(ctx,
               dispatch_open: fn _, _, _, _ -> {:ok, other_id} end
             )

    assert [%{status: :opening} = reserved] = Fixtures.sessions(ctx)
    assert is_binary(reserved.command_id)
    assert reserved.command_id != other_id
    assert Fixtures.owner(ctx).relay_session_id == reserved.id
  end

  test "activation during command dispatch is not regressed to opening", ctx do
    parent = self()

    dispatch = fn _, payload, opts, _ ->
      {:ok, reserved} = RelaySession.get_by_id(payload.relay_session_id, ctx.opts)
      assert {:ok, %{status: :active}} = Fixtures.activate(ctx, reserved, "media-example")
      send(parent, {:open_command, opts[:command_id]})
      {:ok, opts[:command_id]}
    end

    assert {:ok, %{status: :active, command_id: command_id, media_ingest_id: "media-example"}} =
             Fixtures.open(ctx, dispatch_open: dispatch)

    assert_receive {:open_command, ^command_id}
  end

  test "adopts an unambiguous legacy live relay and cannot force a second pull", ctx do
    legacy = Fixtures.legacy(ctx)

    assert {:ok, reused} =
             Fixtures.open(ctx,
               force_new: true,
               dispatch_open: fn _, _, _, _ -> flunk("adoption dispatched a second pull") end
             )

    assert reused.id == legacy.id
    assert reused.status == :active

    assert {:ok, %{relay_session_id: id, epoch: 1}} =
             IngestOwnership.for_relay(legacy.id, ctx.opts)

    assert id == legacy.id
  end

  test "expired ingest gets a new relay while live assignment conflicts refuse another pull",
       ctx do
    legacy = Fixtures.legacy(ctx, gateway_id: "gateway-other")
    assert {:error, :relay_assignment_changed} = Fixtures.open(ctx)
    assert length(Fixtures.sessions(ctx)) == 1

    {:ok, _} =
      RelaySession.renew_lease(
        legacy,
        %{lease_expires_at: DateTime.shift(DateTime.utc_now(), second: -1)},
        ctx.opts
      )

    assert {:ok, replacement} = Fixtures.open(ctx)
    assert replacement.id != legacy.id
    assert replacement.gateway_id == "gateway-example"
  end

  test "viewer detach retains recorder and analysis consumers until each independently releases",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)
    viewer_id = Ecto.UUID.generate()

    {:ok, session} =
      Fixtures.activate(ctx, opening, "media-example", %{viewer_count: 1, viewer_ids: [viewer_id]})

    {:ok, owner} = IngestOwnership.for_relay(session.id, ctx.opts)

    {:ok, recorder} =
      IngestOwnership.acquire_consumer(owner, :recorder, Ecto.UUID.generate(), 30_000, ctx.opts)

    {:ok, analysis} =
      IngestOwnership.acquire_consumer(owner, :analysis, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:ok, %{status: :active}} =
             RelaySessionManager.request_close(session.id,
               actor: ctx.actor,
               reason: "viewer disconnected"
             )

    {:ok, _} =
      RelaySessionLifecycle.heartbeat_session(
        session.id,
        session.media_ingest_id,
        %{renew_ingest?: false, viewer_count: 0, viewer_ids: [], released_viewer_id: viewer_id},
        ctx.opts
      )

    close_opts = [
      actor: ctx.actor,
      reason: "viewer idle timeout",
      dispatch_close: fn _, _, _, _ ->
        {:ok, Ecto.UUID.generate()}
      end
    ]

    assert {:ok, %{status: :active}} = RelaySessionManager.request_close(session.id, close_opts)
    assert :ok = IngestOwnership.release_consumer(owner, recorder.id, ctx.opts)
    assert {:ok, %{status: :active}} = RelaySessionManager.request_close(session.id, close_opts)
    assert :ok = IngestOwnership.release_consumer(owner, analysis.id, ctx.opts)
    assert {:ok, %{status: :closing}} = RelaySessionManager.request_close(session.id, close_opts)
    assert length(Fixtures.sessions(ctx)) == 1
  end

  test "idle close ignores stale display counts and concurrent closers dispatch once", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening, "media-example", %{viewer_count: 4})
    parent = self()

    opts = [
      actor: ctx.actor,
      reason: "viewer idle timeout",
      dispatch_close: fn _, payload, _, _ ->
        send(parent, {:closed, payload.relay_session_id})
        {:ok, Ecto.UUID.generate()}
      end
    ]

    tasks =
      for _ <- 1..4, do: Task.async(fn -> RelaySessionManager.request_close(session.id, opts) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %{status: :closing}}, &1))
    assert_receive {:closed, id}
    assert id == session.id
    refute_received {:closed, _}

    assert {:error, :ownership_lost} =
             IngestOwnership.acquire_consumer(
               Fixtures.owner(ctx),
               :viewer,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )
  end

  test "a delayed close targets only its captured old relay after bounded ownership recovery",
       ctx do
    {:ok, session} = Fixtures.open(ctx)
    parent = self()

    task =
      Task.async(fn ->
        RelaySessionManager.request_close(session.id,
          actor: ctx.actor,
          force: true,
          dispatch_close: fn _, payload, _, _ ->
            send(parent, {:close_waiting, self(), payload.relay_session_id})

            receive do
              :finish -> {:ok, Ecto.UUID.generate()}
            after
              5_000 -> {:error, :test_timeout}
            end
          end
        )
      end)

    assert_receive {:close_waiting, closer, captured_id}, 5_000
    assert captured_id == session.id
    assert {:error, :relay_closing} = Fixtures.open(ctx)
    Fixtures.expire_owner(ctx, Fixtures.owner(ctx))
    assert {:ok, replacement} = Fixtures.open(ctx)
    assert replacement.id != captured_id
    send(closer, :finish)
    assert {:ok, %{id: ^captured_id, status: :closing}} = Task.await(task, 5_000)
    assert {:ok, owner} = IngestOwnership.for_relay(replacement.id, ctx.opts)
    assert owner.epoch == 2
    assert {:ok, %{status: :opening}} = Fixtures.reload(ctx, replacement)
  end

  test "terminal close is idempotent and missing relays report not found", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening)

    {:ok, closed} =
      RelaySessionLifecycle.close_session(session.id, session.media_ingest_id, %{}, ctx.opts)

    assert {:ok, %{status: :closed}} =
             RelaySessionManager.request_close(closed.id,
               actor: ctx.actor,
               dispatch_close: fn _, _, _, _ -> flunk("closed relay dispatched another stop") end
             )

    assert {:error, :not_found} =
             RelaySessionManager.request_close(Ecto.UUID.generate(), ctx.opts)
  end

  test "an unambiguous legacy relay closes on the ownership fence", ctx do
    legacy = Fixtures.legacy(ctx)
    parent = self()

    assert {:ok, %{status: :closing}} =
             RelaySessionManager.request_close(legacy.id,
               actor: ctx.actor,
               reason: "viewer idle timeout",
               dispatch_close: fn _, payload, _, _ ->
                 send(parent, {:stop, payload.relay_session_id})
                 {:ok, Ecto.UUID.generate()}
               end
             )

    assert_receive {:stop, id}
    assert id == legacy.id
    owner = Fixtures.owner(ctx)
    assert owner.state == :closing
    assert owner.relay_session_id == legacy.id
    assert owner.epoch == 1
  end

  test "idle close stops one ambiguous legacy relay without adopting the profile", ctx do
    first = Fixtures.legacy(ctx)
    second = Fixtures.legacy(ctx)
    assert {:error, :ambiguous_live_relays} = Fixtures.open(ctx)
    parent = self()

    dispatch = fn _, payload, _, _ ->
      send(parent, {:stop, payload.relay_session_id, payload.reason})
      {:ok, Ecto.UUID.generate()}
    end

    retained = renew_viewers(ctx, first, 2)

    assert {:ok, %{id: retained_id, status: :active}} =
             RelaySessionManager.request_close(retained.id,
               actor: ctx.actor,
               reason: "viewer idle timeout",
               dispatch_close: dispatch
             )

    assert retained_id == first.id
    refute_received {:stop, _, _}
    assert {:ok, %{status: :active, viewer_count: 2}} = Fixtures.reload(ctx, first)

    ready = renew_viewers(ctx, first, 0)

    assert {:ok, %{status: :closing}} =
             RelaySessionManager.request_close(ready.id,
               actor: ctx.actor,
               reason: "viewer idle timeout",
               dispatch_close: dispatch
             )

    assert_receive {:stop, stopped_id, "viewer idle timeout"}
    assert stopped_id == first.id
    refute_received {:stop, _, _}

    assert {:ok, %{status: :closing}} =
             RelaySessionManager.request_close(first.id,
               actor: ctx.actor,
               reason: "viewer idle timeout",
               dispatch_close: fn _, _, _, _ -> flunk("closing relay dispatched another stop") end
             )

    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, second)
    assert {:error, :ownership_lost} = IngestOwnership.for_relay(first.id, ctx.opts)
    assert {:error, :ownership_lost} = IngestOwnership.for_relay(second.id, ctx.opts)
    owner = Fixtures.owner(ctx)
    assert owner.state == :released
    assert is_nil(owner.relay_session_id)
    assert owner.epoch == 0

    assert {:ok, reused} =
             Fixtures.open(ctx,
               dispatch_open: fn _, _, _, _ ->
                 flunk("the remaining relay dispatched another pull")
               end
             )

    assert reused.id == second.id

    assert {:ok, %{relay_session_id: bound_id, state: :active}} =
             IngestOwnership.for_relay(second.id, ctx.opts)

    assert bound_id == second.id
  end

  test "non-force close retains an unexpired consumer across ambiguous legacy relays", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, owned} = Fixtures.activate(ctx, opening, "media-owned")
    {:ok, lease} = IngestOwnership.for_relay(owned.id, ctx.opts)

    {:ok, _recorder} =
      IngestOwnership.acquire_consumer(lease, :recorder, Ecto.UUID.generate(), 30_000, ctx.opts)

    other = Fixtures.legacy(ctx)
    Fixtures.expire_owner(ctx, Fixtures.owner(ctx))
    parent = self()

    dispatch = fn _, payload, _, _ ->
      send(parent, {:stop, payload.relay_session_id})
      {:ok, Ecto.UUID.generate()}
    end

    assert {:ok, %{status: :active}} =
             RelaySessionManager.request_close(owned.id,
               actor: ctx.actor,
               reason: "viewer idle timeout",
               dispatch_close: dispatch
             )

    refute_received {:stop, _}
    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, owned)
    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, other)
    retained = Fixtures.owner(ctx)
    assert retained.state == :active
    assert retained.relay_session_id == owned.id
    refute DateTime.after?(retained.lease_expires_at, retained.database_now)

    assert {:ok, %{status: :closing}} =
             RelaySessionManager.request_close(owned.id,
               actor: ctx.actor,
               force: true,
               reason: "operator stop",
               dispatch_close: dispatch
             )

    assert_receive {:stop, stopped_id}
    assert stopped_id == owned.id
    refute_received {:stop, _}
    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, other)
    forced = Fixtures.owner(ctx)
    assert forced.state == :active
    assert forced.relay_session_id == owned.id
    assert forced.epoch == retained.epoch
  end

  test "concurrent idle closes of one ambiguous legacy relay dispatch a single stop", ctx do
    first = Fixtures.legacy(ctx)
    second = Fixtures.legacy(ctx)
    parent = self()

    opts = [
      actor: ctx.actor,
      reason: "viewer idle timeout",
      dispatch_close: fn _, payload, _, _ ->
        send(parent, {:stop, payload.relay_session_id})
        {:ok, Ecto.UUID.generate()}
      end
    ]

    tasks =
      for _ <- 1..4, do: Task.async(fn -> RelaySessionManager.request_close(first.id, opts) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %{status: :closing}}, &1))
    assert_receive {:stop, id}
    assert id == first.id
    refute_received {:stop, _}
    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, second)
    owner = Fixtures.owner(ctx)
    assert owner.state == :released
    assert is_nil(owner.relay_session_id)
  end

  test "a failed legacy stop cannot retire the replacement relay", ctx do
    first = renew_viewers(ctx, Fixtures.legacy(ctx), 2)
    second = Fixtures.legacy(ctx)
    parent = self()

    task =
      Task.async(fn ->
        RelaySessionManager.request_close(first.id,
          actor: ctx.actor,
          force: true,
          reason: "operator stop",
          dispatch_close: fn _, payload, _, _ ->
            send(parent, {:close_waiting, payload.relay_session_id})

            receive do
              :fail -> {:error, :delivery_failed}
            after
              10_000 -> {:error, :test_timeout}
            end
          end
        )
      end)

    assert_receive {:close_waiting, captured_id}, 10_000
    assert captured_id == first.id
    assert {:ok, %{status: :closing}} = Fixtures.reload(ctx, first)
    assert {:ok, %{status: :active}} = Fixtures.reload(ctx, second)
    reserved = Fixtures.owner(ctx)
    assert reserved.state == :released
    assert is_nil(reserved.relay_session_id)

    assert {:ok, %{status: :closed}} =
             RelaySessionLifecycle.close_session(
               second.id,
               second.media_ingest_id,
               %{close_reason: "agent stopped relay"},
               ctx.opts
             )

    assert {:ok, replacement} = Fixtures.open(ctx)
    assert replacement.id != captured_id
    send(task.pid, :fail)
    assert {:error, :delivery_failed} = Task.await(task, 10_000)
    assert {:ok, %{status: :failed}} = Fixtures.reload(ctx, first)
    assert {:ok, %{status: :opening}} = Fixtures.reload(ctx, replacement)
    assert {:ok, owner} = IngestOwnership.for_relay(replacement.id, ctx.opts)
    assert owner.relay_session_id == replacement.id
    assert owner.state == :active
    assert {:error, :ownership_lost} = IngestOwnership.for_relay(first.id, ctx.opts)
  end

  test "ambiguous close refuses a relay that is not an authenticated active stream", ctx do
    parent = self()

    dispatch = fn _, payload, _, _ ->
      send(parent, {:stop, payload.relay_session_id})
      {:ok, Ecto.UUID.generate()}
    end

    refused =
      for kind <- [:requested, :opening, :blank, :empty] do
        sibling = leased_session(ctx, kind)
        target = leased_session(ctx, kind)

        assert {:error, :ambiguous_live_relays} =
                 RelaySessionManager.request_close(target.id,
                   actor: ctx.actor,
                   force: true,
                   reason: "viewer idle timeout",
                   dispatch_close: dispatch
                 )

        refute_received {:stop, _}
        assert {:ok, reloaded} = Fixtures.reload(ctx, target)
        assert reloaded.status == sibling.status
        assert reloaded.media_ingest_id in [nil, ""]
        {kind, target}
      end

    assert Fixtures.owner(ctx) == nil

    allowed = leased_session(ctx, :active, "media-authenticated")

    assert {:ok, %{id: closed_id, status: :closing}} =
             RelaySessionManager.request_close(allowed.id,
               actor: ctx.actor,
               force: true,
               reason: "operator stop",
               dispatch_close: dispatch
             )

    assert closed_id == allowed.id
    assert_receive {:stop, ^closed_id}
    refute_received {:stop, _}

    for {_kind, target} <- refused do
      assert {:ok, %{status: status}} = Fixtures.reload(ctx, target)
      assert status != :closing
    end

    assert {:error, :ownership_lost} = IngestOwnership.for_relay(allowed.id, ctx.opts)
  end

  defp wait_for_control_session(partition_id, agent_id, pid, attempts \\ 40)

  defp wait_for_control_session(partition_id, agent_id, pid, 0) do
    flunk("control session #{inspect(pid)} was not visible for #{partition_id}/#{agent_id}")
  end

  defp wait_for_control_session(partition_id, agent_id, pid, attempts) do
    if Enum.any?(AgentCommandBus.lookup_control_session_entries(partition_id, agent_id), fn
         {^pid, _metadata} -> true
         _entry -> false
       end) do
      true
    else
      Process.sleep(25)
      wait_for_control_session(partition_id, agent_id, pid, attempts - 1)
    end
  end

  defp leased_session(ctx, kind, ingest_id \\ nil) do
    lease_expires_at = DateTime.shift(DateTime.utc_now(), second: 30)

    {:ok, session} =
      RelaySession.create_session(
        %{
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.profile.id,
          agent_id: ctx.source.assigned_agent_id,
          gateway_id: ctx.source.assigned_gateway_id,
          lease_expires_at: lease_expires_at
        },
        ctx.opts
      )

    case kind do
      :requested ->
        session

      :opening ->
        {:ok, opening} =
          RelaySession.mark_opening(
            session,
            %{lease_token: "lease-token", lease_expires_at: lease_expires_at},
            ctx.opts
          )

        opening

      :blank ->
        {:ok, active} = RelaySession.activate(session, %{media_ingest_id: nil}, ctx.opts)
        active

      :empty ->
        {:ok, active} = RelaySession.activate(session, %{media_ingest_id: ""}, ctx.opts)
        active

      :active ->
        {:ok, active} = RelaySession.activate(session, %{media_ingest_id: ingest_id}, ctx.opts)
        active
    end
  end

  defp renew_viewers(ctx, session, count) do
    {:ok, updated} =
      RelaySession.renew_lease(
        session,
        %{
          viewer_count: count,
          lease_expires_at: DateTime.shift(DateTime.utc_now(), second: 30)
        },
        ctx.opts
      )

    updated
  end
end
