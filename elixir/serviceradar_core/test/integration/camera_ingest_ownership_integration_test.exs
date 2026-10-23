defmodule ServiceRadar.Camera.IngestOwnershipIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do
    actor = SystemActor.system(:camera_ingest_ownership_test)
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{device_uid: "sr:camera-owner-#{key}", vendor: "acme", vendor_camera_id: key},
        actor: actor
      )

    on_exit(fn -> cleanup(source.id) end)

    {:ok, profile} =
      StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"},
        actor: actor
      )

    %{source: source, profile: profile, actor: actor, opts: [actor: actor]}
  end

  test "concurrent first claims commit one source/profile owner", ctx do
    parent = self()

    claims =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:claim_ready, self()})
          receive do: (:claim -> acquire(ctx))
        end)
      end

    for _ <- claims, do: assert_receive({:claim_ready, _pid}, 5_000)
    Enum.each(claims, &send(&1.pid, :claim))
    results = Enum.map(claims, &Task.await(&1, 10_000))

    assert [{:ok, %{epoch: 1, state: :active} = winner}] =
             Enum.filter(results, &match?({:ok, _}, &1))

    assert Enum.count(results, &(&1 == {:error, :already_owned})) == 7

    assert {:ok, [%{id: id}]} =
             IngestOwner
             |> Ash.Query.filter(
               camera_source_id == ^ctx.source.id and stream_profile_id == ^ctx.profile.id
             )
             |> Ash.read(ctx.opts)

    assert id == winner.id
  end

  test "consumer lifetimes are independent and never exceed owner expiry", ctx do
    assert {:ok, owner} = acquire(ctx)

    consumers =
      for kind <- [:viewer, :recorder, :analysis] do
        assert {:ok, consumer} =
                 IngestOwnership.acquire_consumer(
                   owner,
                   kind,
                   Ecto.UUID.generate(),
                   300_000,
                   ctx.opts
                 )

        assert consumer.expires_at == owner.lease_expires_at
        consumer
      end

    assert [viewer, recorder, analysis] = consumers
    assert {:ok, renewed} = IngestOwnership.renew(owner, 300_000, ctx.opts)
    assert DateTime.after?(renewed.lease_expires_at, owner.lease_expires_at)
    assert {:ok, unchanged} = Ash.get(ConsumerLease, recorder.id, ctx.opts)
    assert unchanged.expires_at == recorder.expires_at

    assert :ok = IngestOwnership.release_consumer(renewed, viewer.id, ctx.opts)
    assert :ok = IngestOwnership.release_consumer(renewed, viewer.id, ctx.opts)
    assert {:error, :consumers_active} = IngestOwnership.begin_idle_close(renewed, ctx.opts)
    assert :ok = IngestOwnership.release_consumer(renewed, analysis.id, ctx.opts)
    assert {:error, :consumers_active} = IngestOwnership.release(renewed, ctx.opts)

    assert {:ok, recorder} =
             IngestOwnership.renew_consumer(renewed, recorder.id, 300_000, ctx.opts)

    assert recorder.expires_at == renewed.lease_expires_at
    assert :ok = IngestOwnership.release_consumer(renewed, recorder.id, ctx.opts)
    assert {:ok, %{state: :closing}} = IngestOwnership.begin_idle_close(renewed, ctx.opts)
  end

  test "idle close captures the old relay, rejects late consumers and permits bounded recovery",
       ctx do
    assert {:ok, owner} = acquire(ctx)

    {:ok, relay} =
      RelaySession.create_session(
        %{
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.profile.id,
          agent_id: "agent-example",
          gateway_id: "gateway-example"
        },
        ctx.opts
      )

    assert {:ok, owner} = IngestOwnership.bind_relay(owner, relay.id, ctx.opts)
    assert {:ok, closing} = IngestOwnership.begin_idle_close(owner, ctx.opts)
    assert closing.relay_session_id == relay.id
    assert DateTime.diff(closing.lease_expires_at, closing.database_now, :millisecond) <= 5_000
    assert {:error, :ownership_lost} = IngestOwnership.renew(closing, 30_000, ctx.opts)

    assert {:error, :ownership_lost} =
             IngestOwnership.acquire_consumer(
               closing,
               :viewer,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert {:error, :already_owned} = acquire(ctx)
    expire_owner(closing, ctx)
    assert {:ok, replacement} = acquire(ctx)
    assert replacement.id == closing.id
    assert replacement.epoch == closing.epoch + 1
    assert replacement.relay_session_id == nil
    assert closing.relay_session_id == relay.id
    assert {:error, :ownership_lost} = IngestOwnership.release(closing, ctx.opts)
  end

  test "takeover fences stale renewals, consumer mutations and publication", ctx do
    assert {:ok, old} = acquire(ctx)

    assert {:ok, consumer} =
             IngestOwnership.acquire_consumer(
               old,
               :recorder,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    expire_owner(old, ctx)
    assert {:ok, current} = acquire(ctx, old.owner_token)
    assert current.epoch == old.epoch + 1
    assert {:error, :ownership_lost} = IngestOwnership.renew(old, 30_000, ctx.opts)

    assert {:error, :ownership_lost} =
             IngestOwnership.renew_consumer(old, consumer.id, 30_000, ctx.opts)

    assert {:error, :ownership_lost} =
             IngestOwnership.release_consumer(old, consumer.id, ctx.opts)

    publish = fn _owner ->
      Source.update_source(ctx.source, %{display_name: "published"}, ctx.opts)
    end

    assert {:error, :ownership_lost} = IngestOwnership.with_current_owner(old, publish, ctx.opts)
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)

    assert {:ok, %{display_name: "published"}} =
             IngestOwnership.with_current_owner(current, publish, ctx.opts)

    # Old-epoch consumers cannot retain a replacement owner.
    assert {:ok, %{state: :closing}} = IngestOwnership.begin_idle_close(current, ctx.opts)
  end

  test "fenced publication rolls back all CNPG writes on failure", ctx do
    assert {:ok, owner} = acquire(ctx)

    result =
      IngestOwnership.with_current_owner(
        owner,
        fn _owner ->
          {:ok, _source} =
            Source.update_source(ctx.source, %{display_name: "must rollback"}, ctx.opts)

          {:error, :publication_rejected}
        end,
        ctx.opts
      )

    assert result == {:error, :publication_rejected}
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
  end

  test "consumer admission and idle close serialize with publication on the owner row", ctx do
    assert {:ok, owner} = acquire(ctx)
    parent = self()

    publisher =
      Task.async(fn ->
        IngestOwnership.with_current_owner(
          owner,
          fn _owner ->
            send(parent, :owner_locked)

            receive do
              :publish -> Source.update_source(ctx.source, %{display_name: "committed"}, ctx.opts)
            after
              5_000 -> {:error, :publication_timed_out}
            end
          end,
          ctx.opts
        )
      end)

    assert_receive :owner_locked, 5_000

    attach =
      Task.async(fn ->
        result =
          IngestOwnership.acquire_consumer(
            owner,
            :recorder,
            Ecto.UUID.generate(),
            30_000,
            ctx.opts
          )

        send(parent, {:attach_finished, result})
        result
      end)

    close =
      Task.async(fn ->
        result = IngestOwnership.begin_idle_close(owner, ctx.opts)
        send(parent, {:close_finished, result})
        result
      end)

    try do
      refute_receive {:attach_finished, _}, 100
      refute_receive {:close_finished, _}, 100
    after
      send(publisher.pid, :publish)
    end

    assert {:ok, %{display_name: "committed"}} = Task.await(publisher, 10_000)

    case {Task.await(attach, 10_000), Task.await(close, 10_000)} do
      {{:ok, %ConsumerLease{}}, {:error, :consumers_active}} -> :ok
      {{:error, :ownership_lost}, {:ok, %{state: :closing}}} -> :ok
      unexpected -> flunk("admission and idle close both won: #{inspect(unexpected)}")
    end
  end

  test "publication cannot commit after its owner lease expires", ctx do
    assert {:ok, owner} =
             IngestOwnership.acquire(
               ctx.source.id,
               ctx.profile.id,
               Ecto.UUID.generate(),
               1_000,
               ctx.opts
             )

    result =
      IngestOwnership.with_current_owner(
        owner,
        fn _owner ->
          send(self(), :publication_started)

          {:ok, _source} =
            Source.update_source(ctx.source, %{display_name: "expired publication"}, ctx.opts)

          Repo.query!("SELECT pg_sleep(1.1)")
          {:ok, :published}
        end,
        ctx.opts
      )

    assert_receive :publication_started
    assert result == {:error, :ownership_lost}
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
    assert {:ok, next} = acquire(ctx)
    assert next.epoch == owner.epoch + 1
  end

  test "absent and ineligible profiles refuse without claiming an owner", ctx do
    assert {:error, :profile_unavailable} =
             IngestOwnership.acquire(
               ctx.source.id,
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert owners(ctx.source.id, ctx.opts) == []

    other = other_source(ctx)

    assert {:error, :profile_unavailable} =
             IngestOwnership.acquire(
               ctx.source.id,
               other.profile.id,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert owners(ctx.source.id, ctx.opts) == []
    assert owners(other.source.id, ctx.opts) == []

    ctx.profile
    |> Ash.Changeset.for_update(:update, %{relay_eligible: false})
    |> Ash.update!(ctx.opts)

    assert {:error, :profile_unavailable} = acquire(ctx)
    assert owners(ctx.source.id, ctx.opts) == []

    ctx.profile
    |> Ash.Changeset.for_update(:update, %{relay_eligible: true})
    |> Ash.update!(ctx.opts)

    assert {:ok, %{epoch: 1, state: :active}} = acquire(ctx)
    assert [%{epoch: 1}] = owners(ctx.source.id, ctx.opts)
  end

  test "absent and ineligible relays refuse without binding the owner", ctx do
    assert {:ok, owner} = acquire(ctx)

    assert {:error, :relay_mismatch} =
             IngestOwnership.bind_relay(owner, Ecto.UUID.generate(), ctx.opts)

    assert %{relay_session_id: nil, epoch: epoch} = reload_owner(owner, ctx)
    assert epoch == owner.epoch

    other = other_source(ctx)

    {:ok, foreign} =
      RelaySession.create_session(
        %{
          camera_source_id: other.source.id,
          stream_profile_id: other.profile.id,
          agent_id: "agent-example",
          gateway_id: "gateway-example"
        },
        ctx.opts
      )

    assert {:error, :relay_mismatch} = IngestOwnership.bind_relay(owner, foreign.id, ctx.opts)
    assert %{relay_session_id: nil} = reload_owner(owner, ctx)

    {:ok, closed} =
      RelaySession.create_session(
        %{
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.profile.id,
          agent_id: "agent-example",
          gateway_id: "gateway-example"
        },
        ctx.opts
      )

    assert {:ok, %{status: :closed}} = RelaySession.mark_closed(closed, %{}, ctx.opts)
    assert {:error, :relay_mismatch} = IngestOwnership.bind_relay(owner, closed.id, ctx.opts)
    assert %{relay_session_id: nil, state: :active} = reload_owner(owner, ctx)

    {:ok, live} =
      RelaySession.create_session(
        %{
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.profile.id,
          agent_id: "agent-example",
          gateway_id: "gateway-example"
        },
        ctx.opts
      )

    assert {:ok, bound} = IngestOwnership.bind_relay(owner, live.id, ctx.opts)
    assert bound.relay_session_id == live.id
  end

  test "release preserves epochs and expired consumers cannot renew", ctx do
    assert {:ok, owner} = acquire(ctx)

    assert {:ok, consumer} =
             IngestOwnership.acquire_consumer(
               owner,
               :viewer,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    consumer
    |> Ash.Changeset.for_update(:renew, %{
      expires_at: DateTime.shift(owner.database_now, second: -1)
    })
    |> Ash.update!(ctx.opts)

    assert {:error, :consumer_expired} =
             IngestOwnership.renew_consumer(owner, consumer.id, 30_000, ctx.opts)

    assert {:ok, %{state: :released}} = IngestOwnership.release(owner, ctx.opts)
    assert {:ok, next} = acquire(ctx)
    assert next.epoch == owner.epoch + 1
    assert next.id == owner.id
  end

  defp other_source(ctx) do
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{device_uid: "sr:camera-owner-#{key}", vendor: "acme", vendor_camera_id: key},
        ctx.opts
      )

    on_exit(fn -> cleanup(source.id) end)

    {:ok, profile} =
      StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"}, ctx.opts)

    %{source: source, profile: profile}
  end

  defp owners(source_id, opts) do
    {:ok, rows} =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^source_id)
      |> Ash.read(opts)

    rows
  end

  defp reload_owner(owner, ctx) do
    {:ok, reloaded} = Ash.get(IngestOwner, owner.id, ctx.opts)
    reloaded
  end

  defp acquire(ctx, token \\ Ecto.UUID.generate()) do
    IngestOwnership.acquire(ctx.source.id, ctx.profile.id, token, 30_000, ctx.opts)
  end

  defp expire_owner(owner, ctx) do
    owner
    |> Ash.Changeset.for_update(:transition, %{
      lease_expires_at: DateTime.shift(owner.database_now, second: -1)
    })
    |> Ash.update!(ctx.opts)
  end

  defp cleanup(source_id) do
    id = Ecto.UUID.dump!(source_id)

    Repo.query!(
      "DELETE FROM platform.camera_consumer_leases WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_ingest_owners WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_relay_sessions WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_stream_profiles WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_sources WHERE id = $1", [id])

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM platform.camera_sources WHERE id = $1", [id])
  end
end
