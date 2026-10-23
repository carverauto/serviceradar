defmodule ServiceRadar.Camera.RelaySessionManagerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do: Fixtures.context()

  test "committed concurrent opens dispatch one pull and reuse its persisted opening reservation",
       ctx do
    parent = self()

    dispatch = fn _agent, payload, _opts, _requester ->
      {:ok, persisted} = RelaySession.get_by_id(payload.relay_session_id, ctx.opts)
      assert persisted.status == :opening
      assert persisted.lease_token == payload.lease_token
      send(parent, {:dispatched, payload.relay_session_id})
      {:ok, Ecto.UUID.generate()}
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

    dispatch = fn agent, payload, opts, requester ->
      send(parent, {:command, agent, payload, opts, requester})
      {:ok, Ecto.UUID.generate()}
    end

    assert {:ok, session} =
             Fixtures.open(ctx,
               scope: %{user: user},
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

  test "activation during command dispatch is not regressed to opening", ctx do
    dispatch = fn _, payload, _, _ ->
      {:ok, reserved} = RelaySession.get_by_id(payload.relay_session_id, ctx.opts)
      assert {:ok, %{status: :active}} = Fixtures.activate(ctx, reserved, "media-example")
      {:ok, "command-example"}
    end

    assert {:ok,
            %{status: :active, command_id: "command-example", media_ingest_id: "media-example"}} =
             Fixtures.open(ctx, dispatch_open: dispatch)
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
end
