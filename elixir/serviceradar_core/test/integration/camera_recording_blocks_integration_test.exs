defmodule ServiceRadar.Camera.RecordingBlocksIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  @clock %{
    "clock_epoch" => "invented-clock",
    "timebase" => 90_000,
    "dts_source" => "pts_no_reordering",
    "utc_mapping" => "unknown"
  }
  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do
    ctx = Fixtures.context()
    {:ok, relay} = Fixtures.open(ctx)
    {:ok, relay} = Fixtures.activate(ctx, relay)
    owner = Fixtures.owner(ctx)

    {:ok, claim} =
      RecorderOwnership.acquire(
        owner,
        Ecto.UUID.generate(),
        relay.media_ingest_id,
        Ecto.UUID.generate(),
        30_000,
        ctx.opts
      )

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, @clock, ctx.opts)
    Map.merge(ctx, %{owner: owner, claim: claim, block: block, relay: relay})
  end

  test "freeze is immutable, identity-bound and survives recorder replacement", ctx do
    descriptor = descriptor(ctx.block)
    assert {:error, :recording_block_unfrozen} = upload(ctx)
    wrong_identity = put_in(descriptor["identity"]["clock"]["clock_epoch"], "substituted-clock")
    assert {:error, :recording_block_mismatch} = freeze(ctx, wrong_identity)
    assert {:ok, frozen} = freeze(ctx, descriptor)
    assert frozen.state == :sealed
    assert {:ok, retry} = freeze(ctx, descriptor)
    assert retry.id == frozen.id
    assert retry.descriptor_sha256 == frozen.descriptor_sha256

    assert {:error, :recording_descriptor_conflict} =
             freeze(ctx, put_in(descriptor["media"]["sha256"], digest("changed")))

    assert {:ok, unfrozen} =
             RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)

    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)

    assert {:ok, replacement} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert replacement.recorder_epoch > ctx.claim.recorder_epoch
    assert {:error, :recorder_claim_lost} = freeze(ctx, descriptor)

    assert {:error, :recording_block_mismatch} =
             RecordingBlocks.freeze(
               ctx.owner,
               replacement,
               unfrozen,
               descriptor(unfrozen),
               ctx.opts
             )

    assert {:error, :recording_block_unfrozen} =
             RecordingBlocks.acquire_upload(unfrozen.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:ok, lease} = upload(ctx)
    assert lease.descriptor == descriptor
    assert lease.storage_id == ctx.claim.storage_id
    assert lease.storage_id != replacement.storage_id
    assert {:ok, :released} = RecordingBlocks.release_upload(lease, ctx.opts)

    assert {:error, :upload_token_reused} =
             RecordingBlocks.acquire_upload(lease.id, lease.upload_token, 30_000, ctx.opts)
  end

  test "independent upload claimants admit one winner and stale generations cannot publish",
       ctx do
    assert {:ok, _} = freeze(ctx, descriptor(ctx.block))
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, :ready)
          receive do: (:go -> upload(ctx))
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :upload_already_owned})) == 7
    assert {:ok, renewed} = RecordingBlocks.renew_upload(winner, 30_000, ctx.opts)
    assert renewed.upload_token == winner.upload_token
    assert {:ok, :released} = RecordingBlocks.release_upload(renewed, ctx.opts)
    assert {:ok, current} = upload(ctx)
    assert current.upload_epoch == winner.upload_epoch + 1
    assert {:error, :upload_lease_lost} = publish(ctx, winner)
    assert {:error, :upload_lease_lost} = RecordingBlocks.renew_upload(winner, 30_000, ctx.opts)
    assert {:error, :upload_lease_lost} = RecordingBlocks.release_upload(winner, ctx.opts)
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
    assert {:ok, %{display_name: "upload fenced"}} = publish(ctx, current)
  end

  test "upload expiry rolls back nested renewal and an executed write after recorder release",
       ctx do
    assert {:ok, _} = freeze(ctx, descriptor(ctx.block))
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)
    assert {:ok, lease} = upload(ctx, 2_000)

    assert {:error, :upload_lease_lost} =
             RecordingBlocks.with_current_upload(
               lease,
               fn _block ->
                 assert {:ok, _renewed} = RecordingBlocks.renew_upload(lease, 30_000, ctx.opts)

                 {:ok, _} =
                   Source.update_source(ctx.source, %{display_name: "must rollback"}, ctx.opts)

                 send(self(), :upload_write_executed)
                 Process.sleep(2_100)
                 :ok
               end,
               ctx.opts
             )

    assert_receive :upload_write_executed
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)
    assert {:ok, next} = upload(ctx)
    assert next.upload_epoch == lease.upload_epoch + 1
    assert next.descriptor_sha256 == lease.descriptor_sha256
  end

  defp freeze(ctx, descriptor),
    do: RecordingBlocks.freeze(ctx.owner, ctx.claim, ctx.block, descriptor, ctx.opts)

  defp upload(ctx, ttl \\ 30_000),
    do: RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), ttl, ctx.opts)

  defp publish(ctx, lease),
    do:
      RecordingBlocks.with_current_upload(
        lease,
        fn _ -> Source.update_source(ctx.source, %{display_name: "upload fenced"}, ctx.opts) end,
        ctx.opts
      )

  # Invented metadata owns the DB authority contract; the worker keeper freezes
  # real synthetic media through Packaging and Spool.
  defp descriptor(block) do
    %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 1, "sha256" => digest("i")},
      "media" => %{"length" => 3, "sha256" => digest("abc")},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 3,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "sha256" => digest("abc"),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
