defmodule ServiceRadar.Camera.RecorderOwnershipIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do
    ctx = Fixtures.context()
    {:ok, relay} = Fixtures.open(ctx)
    {:ok, relay} = Fixtures.activate(ctx, relay)
    Map.merge(ctx, %{owner: Fixtures.owner(ctx), relay: relay, storage_id: Ecto.UUID.generate()})
  end

  test "independent database claimants admit exactly one recorder and one retention lease", ctx do
    results = race(fn -> acquire(ctx) end)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :recorder_already_owned})) == 7
    assert winner.recorder_epoch == 1
    assert winner.storage_id == ctx.storage_id
    assert winner.media_ingest_id == ctx.relay.media_ingest_id
    assert DateTime.compare(winner.lease_expires_at, ctx.owner.lease_expires_at) != :gt

    assert [%{id: id}] =
             ConsumerLease
             |> Ash.Query.filter(ingest_owner_id == ^ctx.owner.id and kind == :recorder)
             |> Ash.read!(ctx.opts)

    assert id == winner.consumer_id
  end

  test "reserved sequences survive caller crashes and released generations never regain publication",
       ctx do
    assert {:ok, old} = acquire(ctx)
    results = race(fn -> RecorderOwnership.reserve_block(ctx.owner, old, ctx.opts) end)
    assert Enum.sort(results) == Enum.map(0..7, &{:ok, &1})
    assert {:ok, 8} = RecorderOwnership.reserve_block(ctx.owner, old, ctx.opts)
    parent = self()

    {allocator, monitor} =
      spawn_monitor(fn ->
        result = RecorderOwnership.reserve_block(ctx.owner, old, ctx.opts)
        send(parent, {:allocated, result})
        receive do: (:unexpected -> :ok), after: (5_000 -> :ok)
      end)

    on_exit(fn -> Process.exit(allocator, :kill) end)
    assert_receive {:allocated, {:ok, 9}}, 5_000
    Process.exit(allocator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^allocator, :killed}, 5_000
    assert {:ok, 10} = RecorderOwnership.reserve_block(ctx.owner, old, ctx.opts)
    assert {:ok, renewed} = RecorderOwnership.renew(ctx.owner, old, 30_000, ctx.opts)
    assert renewed.claim_token == old.claim_token
    assert renewed.recorder_epoch == old.recorder_epoch
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, old, ctx.opts)
    assert {:error, :recorder_token_reused} = acquire(ctx, old.claim_token)
    assert {:ok, current} = acquire(ctx)
    assert current.recorder_epoch == old.recorder_epoch + 1
    assert {:ok, 0} = RecorderOwnership.reserve_block(ctx.owner, current, ctx.opts)

    assert {:error, :recorder_claim_lost} =
             RecorderOwnership.reserve_block(ctx.owner, old, ctx.opts)

    assert {:error, :recorder_claim_lost} =
             RecorderOwnership.renew(ctx.owner, old, 30_000, ctx.opts)

    assert {:error, :recorder_claim_lost} = RecorderOwnership.release(ctx.owner, old, ctx.opts)
    assert {:error, :recorder_claim_lost} = publish(ctx, old)
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
    assert {:ok, %{display_name: "recording published"}} = publish(ctx, current)
  end

  test "expired claim takeover preserves ingest and rejects a stalled publication", ctx do
    assert {:ok, old} = acquire(ctx)
    past = DateTime.shift(old.database_now, second: -1)

    old
    |> Ash.Changeset.for_update(:transition, %{lease_expires_at: past})
    |> Ash.update!(ctx.opts)

    assert {:ok, current} = acquire(ctx)
    assert current.recorder_epoch == old.recorder_epoch + 1
    assert {:ok, owner} = IngestOwnership.for_relay(ctx.relay.id, ctx.opts)
    assert owner.epoch == ctx.owner.epoch
    assert {:error, :recorder_claim_lost} = publish(ctx, old)
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, current, ctx.opts)

    assert {:ok, short} = acquire(ctx, Ecto.UUID.generate(), 2_000)

    assert {:error, :recorder_claim_lost} =
             RecorderOwnership.with_current(
               ctx.owner,
               short,
               fn _owner, _claim ->
                 Process.sleep(2_100)

                 {:ok, _source} =
                   Source.update_source(ctx.source, %{display_name: "must rollback"}, ctx.opts)

                 send(self(), :publication_write_executed)
                 :ok
               end,
               ctx.opts
             )

    assert_receive :publication_write_executed
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
  end

  test "claim acquisition requires persisted active ingress and explicit storage identity", ctx do
    assert {:error, :recorder_ingest_mismatch} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               "other-ingest",
               ctx.storage_id,
               30_000,
               ctx.opts
             )

    assert {:error, :invalid_recorder_identity} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               nil,
               30_000,
               ctx.opts
             )

    assert {:ok, _closing} = RelaySession.request_close(ctx.relay, %{}, ctx.opts)
    assert {:error, :recorder_ingest_mismatch} = acquire(ctx)

    assert [] ==
             RecorderClaim
             |> Ash.Query.filter(ingest_owner_id == ^ctx.owner.id)
             |> Ash.read!(ctx.opts)
  end

  test "a shorter legacy relay caps receipts and rolls back publication after relay expiry",
       ctx do
    relay_expiry = DateTime.shift(ctx.owner.database_now, second: 5)

    assert {:ok, relay} =
             RelaySession.renew_lease(ctx.relay, %{lease_expires_at: relay_expiry}, ctx.opts)

    Fixtures.expire_owner(ctx, ctx.owner)

    # Reuse adopts a still-live relay without extending its media lease.
    assert {:ok, reused} = Fixtures.open(ctx)
    assert reused.id == relay.id
    assert reused.lease_expires_at == relay_expiry
    owner = Fixtures.owner(ctx)
    assert DateTime.after?(owner.lease_expires_at, relay_expiry)
    ctx = %{ctx | owner: owner, relay: reused}

    assert {:ok, claim} = acquire(ctx)
    assert claim.lease_expires_at == relay_expiry
    assert {:ok, renewed} = RecorderOwnership.renew(owner, claim, 30_000, ctx.opts)
    assert renewed.lease_expires_at == relay_expiry

    assert [consumer] =
             ConsumerLease
             |> Ash.Query.filter(id == ^claim.consumer_id)
             |> Ash.read!(ctx.opts)

    assert consumer.expires_at == relay_expiry

    # Recreate a pre-cap persisted claim/consumer. Only the relay expires during
    # publication, so the claim or owner deadline cannot mask a missing recheck.
    consumer
    |> Ash.Changeset.for_update(:renew, %{expires_at: owner.lease_expires_at})
    |> Ash.update!(ctx.opts)

    legacy_claim =
      renewed
      |> Ash.Changeset.for_update(:transition, %{lease_expires_at: owner.lease_expires_at})
      |> Ash.update!(Keyword.put(ctx.opts, :load, [:database_now]))

    assert DateTime.after?(relay_expiry, legacy_claim.database_now)

    assert {:error, :recorder_ingest_mismatch} =
             RecorderOwnership.with_current(
               owner,
               legacy_claim,
               fn _owner, current ->
                 assert DateTime.after?(current.lease_expires_at, relay_expiry)

                 {:ok, _source} =
                   Source.update_source(ctx.source, %{display_name: "must rollback"}, ctx.opts)

                 send(self(), :relay_publication_write_executed)

                 Process.sleep(
                   DateTime.diff(relay_expiry, current.database_now, :millisecond) + 100
                 )

                 :ok
               end,
               ctx.opts
             )

    assert_receive :relay_publication_write_executed
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
    assert {:ok, _owner} = IngestOwnership.for_relay(relay.id, ctx.opts)
  end

  defp acquire(ctx, token \\ Ecto.UUID.generate(), ttl \\ 30_000),
    do:
      RecorderOwnership.acquire(
        ctx.owner,
        token,
        ctx.relay.media_ingest_id,
        ctx.storage_id,
        ttl,
        ctx.opts
      )

  defp publish(ctx, claim) do
    RecorderOwnership.with_current(
      ctx.owner,
      claim,
      fn _owner, _claim ->
        Source.update_source(ctx.source, %{display_name: "recording published"}, ctx.opts)
      end,
      ctx.opts
    )
  end

  defp race(fun) do
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, :ready)
          receive do: (:go -> fun.())
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end
end
