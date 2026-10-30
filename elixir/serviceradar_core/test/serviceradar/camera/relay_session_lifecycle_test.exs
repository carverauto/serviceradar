defmodule ServiceRadar.Camera.RelaySessionLifecycleTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do: Fixtures.context()

  test "activation binds authenticated assignment and persists media metadata using database time",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)

    assert {:ok, session} =
             Fixtures.activate(ctx, opening, "media-example", %{
               source_incarnation_id: "b0ede4c7-23ca-412f-91ad-77ce4ae8e33c",
               lease_expires_at_unix: 4_000_000_000,
               viewer_count: 2,
               viewer_ids: [Ecto.UUID.generate(), Ecto.UUID.generate()]
             })

    owner = Fixtures.owner(ctx)
    assert session.status == :active
    assert session.media_ingest_id == "media-example"

    assert {:ok, %{source_incarnation_id: "b0ede4c7-23ca-412f-91ad-77ce4ae8e33c"}} =
             Fixtures.reload(ctx, session)

    assert session.viewer_count == 2
    assert session.lease_expires_at == owner.lease_expires_at
    assert DateTime.diff(owner.lease_expires_at, owner.database_now, :second) in 0..30
    assert [%{kind: :viewer}, %{kind: :viewer}] = consumers(ctx, owner)
  end

  test "repeat activation cannot change or remove the bound source runtime", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    incarnation = Ecto.UUID.generate()
    attrs = %{source_incarnation_id: incarnation}
    {:ok, active} = Fixtures.activate(ctx, opening, "media-example", attrs)
    assert {:ok, repeated} = Fixtures.activate(ctx, active, "media-example", attrs)
    assert repeated.source_incarnation_id == incarnation
    before = Fixtures.owner(ctx)

    for supplied <- [Ecto.UUID.generate(), nil, ""] do
      assert {:error, :source_incarnation_mismatch} =
               Fixtures.activate(ctx, active, "media-example", %{source_incarnation_id: supplied})

      assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at

      assert {:ok, %{source_incarnation_id: ^incarnation, status: :active}} =
               Fixtures.reload(ctx, active)
    end
  end

  test "an already active legacy relay remains unknown and cannot adopt a new runtime", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, active} = Fixtures.activate(ctx, opening, "media-example", %{source_incarnation_id: ""})
    assert {:ok, %{source_incarnation_id: nil}} = Fixtures.activate(ctx, active, "media-example")
    before = Fixtures.owner(ctx)

    assert {:error, :source_incarnation_mismatch} =
             Fixtures.activate(ctx, active, "media-example", %{
               source_incarnation_id: Ecto.UUID.generate()
             })

    assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at
    assert {:ok, %{source_incarnation_id: nil, status: :active}} = Fixtures.reload(ctx, active)
  end

  test "malformed runtime identity leaves an opening reservation untouched", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    before = Fixtures.owner(ctx)

    for supplied <- ["invalid", String.duplicate("z", 36), 42] do
      assert {:error, :invalid_source_incarnation} =
               Fixtures.activate(ctx, opening, "media-example", %{source_incarnation_id: supplied})

      assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at

      assert {:ok, %{source_incarnation_id: nil, media_ingest_id: nil, status: :opening}} =
               Fixtures.reload(ctx, opening)
    end
  end

  for field <- [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id] do
    test "activation rejects a forged #{field} without activating the reserved relay", ctx do
      {:ok, opening} = Fixtures.open(ctx)

      assert {:error, :relay_assignment_mismatch} =
               Fixtures.activate(ctx, opening, "media-example", %{
                 unquote(field) => Ecto.UUID.generate()
               })

      assert {:ok, %{status: :opening, media_ingest_id: nil}} = Fixtures.reload(ctx, opening)
    end
  end

  test "media heartbeat renews current viewers without implicitly renewing an independent recorder",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)
    viewer_id = Ecto.UUID.generate()

    {:ok, session} =
      Fixtures.activate(ctx, opening, "media-example", %{viewer_ids: [viewer_id], viewer_count: 1})

    old = Fixtures.owner(ctx)

    {:ok, recorder} =
      IngestOwnership.acquire_consumer(old, :recorder, Ecto.UUID.generate(), 1_000, ctx.opts)

    assert %DateTime{} = recorder.database_now
    assert DateTime.diff(recorder.expires_at, recorder.database_now, :millisecond) in 0..1_000

    assert {:ok, renewed} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{renew_ingest?: true, viewer_count: 1, viewer_ids: [viewer_id]},
               ctx.opts
             )

    owner = Fixtures.owner(ctx)
    assert DateTime.after?(owner.lease_expires_at, old.lease_expires_at)
    assert renewed.lease_expires_at == owner.lease_expires_at
    assert {:ok, unchanged} = Ash.get(ConsumerLease, recorder.id, ctx.opts)
    assert unchanged.expires_at == recorder.expires_at
    assert [%{expires_at: expiry}] = Enum.filter(consumers(ctx, owner), &(&1.kind == :viewer))
    assert expiry == owner.lease_expires_at
  end

  test "viewer-only sync releases one viewer without extending ingest or another consumer", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    [first, second] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    {:ok, session} =
      Fixtures.activate(ctx, opening, "media-example", %{
        viewer_ids: [first, second],
        viewer_count: 2
      })

    before = Fixtures.owner(ctx)

    assert {:ok, updated} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{
                 renew_ingest?: false,
                 viewer_count: 1,
                 viewer_ids: [second],
                 released_viewer_id: first
               },
               ctx.opts
             )

    after_owner = Fixtures.owner(ctx)
    assert after_owner.lease_expires_at == before.lease_expires_at
    assert updated.lease_expires_at == session.lease_expires_at
    assert updated.viewer_count == 1
    assert [%{consumer_key: ^second}] = consumers(ctx, after_owner)
    Fixtures.expire_owner(ctx, after_owner)

    assert {:error, :ownership_lost} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{renew_ingest?: false, viewer_count: 1, viewer_ids: [second]},
               ctx.opts
             )
  end

  test "repeat activation preserves the ingest identity and mismatched media cannot renew", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening, "media-example")
    assert {:ok, repeated} = Fixtures.activate(ctx, session, "media-example", %{viewer_count: 2})
    assert repeated.media_ingest_id == session.media_ingest_id
    before = Fixtures.owner(ctx)

    assert {:error, :media_ingest_mismatch} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               "media-forged",
               %{viewer_count: 3},
               ctx.opts
             )

    assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at
  end

  for acknowledgement <- [nil, "camera relay drain acknowledged"] do
    test "closing heartbeat does not renew and #{inspect(acknowledgement)} preserves the operator reason",
         ctx do
      {:ok, opening} = Fixtures.open(ctx)
      {:ok, session} = Fixtures.activate(ctx, opening)

      {:ok, closing} =
        ServiceRadar.Camera.RelaySessionManager.request_close(session.id,
          actor: ctx.actor,
          force: true,
          reason: "viewer idle timeout",
          dispatch_close: fn _, _, _, _ -> {:ok, Ecto.UUID.generate()} end
        )

      before = Fixtures.owner(ctx)

      assert {:ok, %{status: :closing}} =
               RelaySessionLifecycle.heartbeat_session(
                 session.id,
                 session.media_ingest_id,
                 %{viewer_count: 1},
                 ctx.opts
               )

      assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at

      assert {:ok, closed} =
               RelaySessionLifecycle.close_session(
                 closing.id,
                 session.media_ingest_id,
                 %{close_reason: unquote(acknowledgement), viewer_count: 0},
                 ctx.opts
               )

      assert closed.status == :closed
      assert closed.close_reason == "viewer idle timeout"
      assert Fixtures.owner(ctx).state == :released
    end
  end

  test "media close and failure persist their reasons and reject activation after termination",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening)

    assert {:ok, failed} =
             RelaySessionLifecycle.fail_session(
               session.id,
               session.media_ingest_id,
               %{failure_reason: "synthetic disconnect", close_reason: "media ingress failed"},
               ctx.opts
             )

    assert failed.failure_reason == "synthetic disconnect"
    assert failed.close_reason == "media ingress failed"
    assert failed.status == :failed
    assert Fixtures.owner(ctx).state == :released

    assert {:error, {:invalid_status, :failed}} =
             Fixtures.activate(ctx, failed, session.media_ingest_id)

    assert {:error, :not_found} =
             RelaySessionLifecycle.activate_session(
               Ecto.UUID.generate(),
               "media-example",
               %{},
               ctx.opts
             )
  end

  test "ambiguous legacy streams continue authenticated media but deny adoption until repaired",
       ctx do
    first = Fixtures.legacy(ctx)
    second = Fixtures.legacy(ctx)
    assert {:error, :ambiguous_live_relays} = Fixtures.open(ctx)
    assert {:error, :ownership_lost} = IngestOwnership.for_relay(first.id, ctx.opts)

    assert {:ok, %{status: :active}} =
             RelaySessionLifecycle.heartbeat_session(
               first.id,
               first.media_ingest_id,
               %{viewer_count: 1},
               ctx.opts
             )

    assert {:ok, %{status: :active}} =
             RelaySessionLifecycle.heartbeat_session(
               second.id,
               second.media_ingest_id,
               %{viewer_count: 1},
               ctx.opts
             )

    assert {:error, :ownership_lost} = IngestOwnership.for_relay(second.id, ctx.opts)

    assert {:ok, _} =
             RelaySessionLifecycle.close_session(
               second.id,
               second.media_ingest_id,
               %{close_reason: "agent stopped relay"},
               ctx.opts
             )

    assert {:ok, %{status: :active}} =
             RelaySessionLifecycle.heartbeat_session(
               first.id,
               first.media_ingest_id,
               %{},
               ctx.opts
             )

    assert {:ok, %{relay_session_id: id}} = IngestOwnership.for_relay(first.id, ctx.opts)
    assert id == first.id
  end

  test "authenticated recovery advances the epoch and old relay completion cannot retire a replacement",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening)
    old = Fixtures.owner(ctx)
    Fixtures.expire_owner(ctx, old)

    assert {:ok, _} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{},
               ctx.opts
             )

    recovered = Fixtures.owner(ctx)
    assert recovered.epoch == old.epoch + 1
    assert {:error, :ownership_lost} = IngestOwnership.renew(old, 30_000, ctx.opts)

    Fixtures.expire_owner(ctx, recovered)

    {:ok, _} =
      RelaySession.renew_lease(
        session,
        %{lease_expires_at: DateTime.shift(DateTime.utc_now(), second: -1)},
        ctx.opts
      )

    {:ok, replacement} = Fixtures.open(ctx)

    assert {:error, :ownership_lost} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{},
               ctx.opts
             )

    assert {:ok, %{status: :closed}} =
             RelaySessionLifecycle.close_session(
               session.id,
               session.media_ingest_id,
               %{close_reason: "agent stopped relay"},
               ctx.opts
             )

    assert {:ok, %{relay_session_id: id}} = IngestOwnership.for_relay(replacement.id, ctx.opts)
    assert id == replacement.id
  end

  test "a failing viewer batch rolls back earlier batches and the associated heartbeat renewal",
       ctx do
    {:ok, opening} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, opening)
    before = Fixtures.owner(ctx)
    viewer_ids = Enum.map(1..300, fn _ -> Ecto.UUID.generate() end)

    assert {:error, _} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{viewer_ids: viewer_ids ++ ["invalid-viewer-id"], viewer_count: 301},
               ctx.opts
             )

    assert consumers(ctx, before) == []
    assert Fixtures.owner(ctx).lease_expires_at == before.lease_expires_at

    assert {:ok, renewed} =
             RelaySessionLifecycle.heartbeat_session(
               session.id,
               session.media_ingest_id,
               %{viewer_ids: viewer_ids, viewer_count: 300},
               ctx.opts
             )

    assert renewed.viewer_count == 300
    assert length(consumers(ctx, Fixtures.owner(ctx))) == 300
  end

  test "cleanup removes at most its batch and retains live leases and owner epoch history", ctx do
    {:ok, opening} = Fixtures.open(ctx)
    owner = Fixtures.owner(ctx)

    {:ok, oldest} =
      ConsumerLease
      |> Ash.Query.sort(expires_at: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read_one(ctx.opts)

    baseline = if oldest, do: oldest.expires_at, else: owner.database_now
    before_all = DateTime.shift(Enum.min([baseline, owner.database_now], DateTime), second: -1)

    expired =
      for _ <- 1..2 do
        {:ok, consumer} =
          IngestOwnership.acquire_consumer(
            owner,
            :analysis,
            Ecto.UUID.generate(),
            30_000,
            ctx.opts
          )

        consumer
        |> Ash.Changeset.for_update(:renew, %{expires_at: before_all})
        |> Ash.update!(ctx.opts)
      end

    {:ok, live} =
      IngestOwnership.acquire_consumer(owner, :recorder, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:ok, %{deleted: 1, skipped: 0, failed: 0}} =
             IngestOwnership.prune_consumers(actor: ctx.actor, batch_size: 1)

    remaining = consumers(ctx, owner)
    assert length(remaining) == 2
    assert Enum.any?(remaining, &(&1.id == live.id))
    assert Enum.count(remaining, &(&1.id in Enum.map(expired, fn item -> item.id end))) == 1

    assert {:ok, %{deleted: 1, failed: 0}} =
             IngestOwnership.prune_consumers(actor: ctx.actor, batch_size: 1)

    assert [%{id: id}] = consumers(ctx, owner)
    assert id == live.id
    assert {:ok, current} = IngestOwnership.for_relay(opening.id, ctx.opts)
    assert current.epoch == owner.epoch
  end

  defp consumers(ctx, owner) do
    ConsumerLease
    |> Ash.Query.filter(ingest_owner_id == ^owner.id and owner_epoch == ^owner.epoch)
    |> Ash.read!(ctx.opts)
  end
end
