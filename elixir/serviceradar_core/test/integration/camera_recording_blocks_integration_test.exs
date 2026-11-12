defmodule ServiceRadar.Camera.RecordingBlocksIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.LocalPublicationIntent
  alias ServiceRadar.Camera.LocalPublicationIntents
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  @clock %{
    "clock_epoch" => "invented-clock",
    "timebase" => 90_000,
    "dts_source" => "pts_no_reordering",
    "utc_mapping" => "unknown"
  }
  @moduletag :integration
  @moduletag sandbox: :unboxed
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    recovery = Fixtures.recording_recovery_gate(directory)
    Fixtures.preserve_recording_control()
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
    Map.merge(ctx, %{owner: owner, claim: claim, block: block, relay: relay, recovery: recovery})
  end

  test "local intent acknowledgement binds frozen history without granting availability", ctx do
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)
    assert {:error, :recording_block_unfrozen} = LocalPublicationIntents.accept(bytes, ctx.opts)
    assert {:ok, frozen} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    assert {:error, _} = LocalPublicationIntents.accept(bytes, actor: %{role: :viewer})

    assert {:ok, {:error, :ambient_transaction}} =
             Repo.transaction(fn -> LocalPublicationIntents.accept(bytes, ctx.opts) end)

    assert {:ok, nil} =
             Ash.get(
               LocalPublicationIntent,
               operation,
               Keyword.put(ctx.opts, :not_found_error?, false)
             )

    for altered <- [
          %{ctx.block | storage_id: Ecto.UUID.generate()},
          %{ctx.block | clock: Map.put(@clock, "clock_epoch", "substituted-clock")}
        ] do
      assert {:error, :local_publication_authority_mismatch} =
               LocalPublicationIntents.accept(Fixtures.local_intent(altered, operation), ctx.opts)
    end

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

    assert {:ok, ack} = LocalPublicationIntents.accept(bytes, ctx.opts)

    assert Jason.decode!(ack) == %{
             "version" => 1,
             "kind" => "intent_accepted",
             "operation_id" => operation,
             "intent_sha256" => digest(bytes)
           }

    assert {:ok, persisted} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    assert persisted.recording_block_id == frozen.id
    assert persisted.storage_id == ctx.claim.storage_id
    assert persisted.intent_sha256 == digest(bytes)
    assert persisted.descriptor_sha256 == frozen.descriptor_sha256
    assert {:ok, ^ack} = LocalPublicationIntents.accept(bytes, ctx.opts)
    assert {:ok, retry} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    assert retry.inserted_at == persisted.inserted_at
    assert {:error, _} = LocalPublicationIntents.accept(bytes, actor: %{role: :viewer})

    assert {:error, :local_publication_intent_conflict} =
             LocalPublicationIntents.accept(
               Fixtures.local_intent(ctx.block, Ecto.UUID.generate()),
               ctx.opts
             )

    assert {:ok, original} = Ash.get(RecordingBlock, frozen.id, ctx.opts)
    assert original.state == :sealed
    assert is_nil(original.archive_binding_id)
    assert is_nil(original.archive_published_at)
    assert is_nil(original.upload_token)

    assert {:ok, other} =
             RecorderOwnership.reserve_block(ctx.owner, replacement, @clock, ctx.opts)

    assert {:ok, other} =
             RecordingBlocks.freeze(
               ctx.owner,
               replacement,
               other,
               Fixtures.recording_descriptor(other),
               ctx.opts
             )

    assert {:error, :local_publication_intent_conflict} =
             LocalPublicationIntents.accept(Fixtures.local_intent(other, operation), ctx.opts)

    assert {:ok, unchanged} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    assert unchanged.recording_block_id == frozen.id
  end

  test "closed deployment state refuses new intents and retries without changing receipts", ctx do
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)
    lookup = Keyword.put(ctx.opts, :not_found_error?, false)

    File.rm!(ctx.recovery.path)
    assert {:error, :nvr_recovery_closed} = LocalPublicationIntents.accept(bytes, ctx.opts)
    assert {:ok, nil} = Ash.get(LocalPublicationIntent, operation, lookup)

    File.write!(ctx.recovery.path, ctx.recovery.ready)
    assert {:ok, acknowledgement} = LocalPublicationIntents.accept(bytes, ctx.opts)
    assert {:ok, receipt} = Ash.get(LocalPublicationIntent, operation, ctx.opts)

    for state <- [
          String.replace(ctx.recovery.ready, "ready", "closed"),
          ~s({"generation":"#{Ecto.UUID.generate()}","state":"ready"})
        ] do
      File.write!(ctx.recovery.path, state)
      assert {:error, :nvr_recovery_closed} = LocalPublicationIntents.accept(bytes, ctx.opts)
      assert {:ok, unchanged} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
      assert unchanged.inserted_at == receipt.inserted_at
    end

    File.write!(ctx.recovery.path, ctx.recovery.ready)
    assert {:ok, ^acknowledgement} = LocalPublicationIntents.accept(bytes, ctx.opts)
  end

  test "closure during acceptance withholds the reply but preserves the committed intent", ctx do
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)

    assert {:error, :nvr_recovery_closed} =
             close_recovery_during_query(
               ctx,
               fn query ->
                 String.starts_with?(query, "INSERT INTO") and
                   String.contains?(query, "camera_local_publication_intents")
               end,
               fn -> LocalPublicationIntents.accept(bytes, ctx.opts) end
             )

    assert {:ok, receipt} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    File.write!(ctx.recovery.path, ctx.recovery.ready)
    assert {:ok, acknowledgement} = LocalPublicationIntents.accept(bytes, ctx.opts)
    assert Jason.decode!(acknowledgement)["operation_id"] == operation
    assert {:ok, retry} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    assert retry.inserted_at == receipt.inserted_at
  end

  test "competing local operations retain one acknowledgement and exact concurrent retries converge",
       ctx do
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    bytes = for _ <- 1..2, do: Fixtures.local_intent(ctx.block, Ecto.UUID.generate())
    parent = self()

    tasks =
      for intent <- bytes do
        Task.async(fn ->
          send(parent, :ready)
          receive do: (:go -> LocalPublicationIntents.accept(intent, ctx.opts))
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, :local_publication_intent_conflict}] =
             Enum.filter(results, &match?({:error, _}, &1))

    operation = Jason.decode!(winner)["operation_id"]
    winning_bytes = Enum.find(bytes, &(Jason.decode!(&1)["operation_id"] == operation))
    assert {:ok, persisted} = Ash.get(LocalPublicationIntent, operation, ctx.opts)

    retries =
      for _ <- 1..2,
          do: Task.async(fn -> LocalPublicationIntents.accept(winning_bytes, ctx.opts) end)

    for task <- retries do
      assert {:ok, ^winner} = Task.await(task, 10_000)
    end

    assert {:ok, retry} = Ash.get(LocalPublicationIntent, operation, ctx.opts)
    assert retry.inserted_at == persisted.inserted_at
  end

  test "freeze is immutable, identity-bound and survives recorder replacement", ctx do
    descriptor = Fixtures.recording_descriptor(ctx.block)
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
               Fixtures.recording_descriptor(unfrozen),
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

  test "upload acquisition and renewal require ready recovery outside transactions", ctx do
    assert {:ok, frozen} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    token = Ecto.UUID.generate()

    assert {:ok, {:error, :ambient_transaction}} =
             Repo.transaction(fn ->
               RecordingBlocks.acquire_upload(frozen.id, token, 30_000, ctx.opts)
             end)

    File.rm!(ctx.recovery.path)

    assert {:error, :nvr_recovery_closed} =
             RecordingBlocks.acquire_upload(frozen.id, token, 30_000, ctx.opts)

    assert {:ok, unchanged} = Ash.get(RecordingBlock, frozen.id, ctx.opts)
    assert unchanged.state == :sealed
    assert unchanged.upload_epoch == frozen.upload_epoch
    assert unchanged.upload_token == nil
    assert unchanged.upload_expires_at == nil

    File.write!(ctx.recovery.path, ctx.recovery.ready)
    assert {:ok, lease} = RecordingBlocks.acquire_upload(frozen.id, token, 30_000, ctx.opts)
    File.rm!(ctx.recovery.path)
    assert {:error, :nvr_recovery_closed} = RecordingBlocks.renew_upload(lease, 300_000, ctx.opts)

    assert {:ok, {:error, :ambient_transaction}} =
             Repo.transaction(fn -> RecordingBlocks.renew_upload(lease, 300_000, ctx.opts) end)

    assert {:ok, unchanged} = Ash.get(RecordingBlock, frozen.id, ctx.opts)
    assert unchanged.upload_token == lease.upload_token
    assert unchanged.upload_epoch == lease.upload_epoch
    assert unchanged.upload_expires_at == lease.upload_expires_at
    assert {:ok, :released} = RecordingBlocks.release_upload(lease, ctx.opts)

    File.write!(ctx.recovery.path, ctx.recovery.ready)
    assert {:ok, replacement} = upload(ctx)
    assert replacement.upload_epoch == lease.upload_epoch + 1
    assert replacement.descriptor_sha256 == frozen.descriptor_sha256
    assert {:ok, renewed} = RecordingBlocks.renew_upload(replacement, 300_000, ctx.opts)
    assert DateTime.after?(renewed.upload_expires_at, replacement.upload_expires_at)
  end

  for operation <- [:acquire, :renew] do
    test "recovery closure during upload #{operation} withholds success but retains the committed lease",
         ctx do
      assert {:ok, frozen} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
      operation = unquote(operation)
      token = Ecto.UUID.generate()

      before =
        case operation do
          :acquire ->
            frozen

          :renew ->
            {:ok, lease} = RecordingBlocks.acquire_upload(frozen.id, token, 30_000, ctx.opts)
            lease
        end

      work = fn ->
        case operation do
          :acquire -> RecordingBlocks.acquire_upload(frozen.id, token, 300_000, ctx.opts)
          :renew -> RecordingBlocks.renew_upload(before, 300_000, ctx.opts)
        end
      end

      assert {:error, :nvr_recovery_closed} =
               close_recovery_during_query(
                 ctx,
                 fn query ->
                   String.starts_with?(query, "UPDATE") and
                     String.contains?(query, "camera_recording_blocks")
                 end,
                 work
               )

      assert {:ok, retained} = Ash.get(RecordingBlock, frozen.id, ctx.opts)
      assert retained.state == :uploading
      assert retained.upload_token == token
      assert retained.descriptor_sha256 == frozen.descriptor_sha256
      assert {:error, :nvr_recovery_closed} = work.()
      File.write!(ctx.recovery.path, ctx.recovery.ready)

      case operation do
        :acquire ->
          assert retained.upload_epoch == before.upload_epoch + 1
          assert %DateTime{} = retained.upload_expires_at
          assert {:error, :upload_already_owned} = work.()
          assert {:error, :upload_already_owned} = upload(ctx)

        :renew ->
          assert retained.upload_epoch == before.upload_epoch
          assert DateTime.after?(retained.upload_expires_at, before.upload_expires_at)
          assert {:ok, renewed} = work.()
          assert renewed.upload_token == token
          assert renewed.upload_epoch == before.upload_epoch
      end
    end
  end

  test "independent upload claimants admit one winner and stale generations cannot publish",
       ctx do
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
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

  test "upload expiry rolls back a resource renewal and an executed write after recorder release",
       ctx do
    binding = register_binding(ctx)
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)
    assert {:ok, lease} = upload(ctx, 2_000)

    assert {:error, :upload_lease_lost} =
             RecordingBlocks.with_current_upload(
               lease,
               fn block ->
                 assert {:error, :ambient_transaction} =
                          RecordingBlocks.renew_upload(lease, 30_000, ctx.opts)

                 assert {:ok, _renewed} =
                          block
                          |> Ash.Changeset.for_update(:renew_upload, %{
                            upload_expires_at:
                              DateTime.add(block.database_now, 30_000, :millisecond)
                          })
                          |> Ash.update(ctx.opts)

                 assert {:ok, _bound} = bind(ctx, lease, binding)

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
    assert next.archive_binding_id == nil
  end

  test "a retained operation deadline rolls back an executed write despite a renewed lease",
       ctx do
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    assert {:ok, lease} = upload(ctx)
    deadline = DateTime.add(lease.database_now, 2_000, :millisecond)
    assert {:ok, _} = RecordingBlocks.renew_upload(lease, 30_000, ctx.opts)

    assert {:error, :upload_dispatch_expired} =
             RecordingBlocks.with_current_upload(
               lease,
               fn _block ->
                 assert {:ok, _} =
                          Source.update_source(
                            ctx.source,
                            %{display_name: "capped write"},
                            ctx.opts
                          )

                 send(self(), :capped_write_executed)
                 Process.sleep(2_100)
                 :ok
               end,
               deadline,
               ctx.opts
             )

    assert_receive :capped_write_executed
    assert {:ok, %{display_name: nil}} = Source.get_by_id(ctx.source.id, ctx.opts)

    assert {:error, :upload_dispatch_expired} =
             RecordingBlocks.with_current_upload(
               lease,
               fn _ -> flunk("expired callback ran") end,
               deadline,
               ctx.opts
             )

    assert {:error, :invalid_upload_deadline} =
             RecordingBlocks.with_current_upload(
               lease,
               fn _ -> flunk("invalid callback ran") end,
               nil,
               ctx.opts
             )

    assert :ok = RecordingBlocks.with_current_upload(lease, fn _ -> :ok end, ctx.opts)
  end

  test "destination registration retains exact unqualified generations and rejects substitution",
       ctx do
    input = Fixtures.archive_destination(Ecto.UUID.generate())
    binding = register_binding(ctx, input)
    assert {:ok, retry} = ArchiveBinding.register(input, ctx.opts)
    assert retry.id == binding.id and retry.capability_state == :unqualified

    assert {:error, _} =
             ArchiveBinding.register(Map.put(input, "bucket", "example-substitution"), ctx.opts)

    assert {:ok, retained} = Ash.get(ArchiveBinding, binding.id, ctx.opts)

    assert retained.bucket == "example-recordings" and
             retained.destination_sha256 == binding.destination_sha256

    next = register_binding(ctx, Map.put(input, "generation", 2))
    assert next.id != binding.id and next.destination_sha256 != binding.destination_sha256
    assert {:error, _} = ArchiveBinding.register(input, actor: %{role: :viewer})
  end

  test "binding requires exact authority and cannot replace the retained destination", ctx do
    first = register_binding(ctx)
    second = register_binding(ctx)
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    assert {:ok, lease} = upload(ctx)

    assert {:error, :archive_binding_mismatch} =
             RecordingBlocks.bind_archive(lease, first.id, digest("wrong destination"), ctx.opts)

    assert {:error, :upload_lease_lost} =
             bind(ctx, %{lease | descriptor_sha256: digest("wrong descriptor")}, first)

    assert {:ok, bound} = bind(ctx, lease, first)
    assert bound.archive_binding_id == first.id and bound.storage_id == lease.storage_id
    assert bound.descriptor_sha256 == lease.descriptor_sha256 and bound.state == :uploading
    assert {:ok, retry} = bind(ctx, lease, first)
    assert retry.archive_binding_id == first.id
    assert {:error, :archive_binding_conflict} = bind(ctx, lease, second)

    assert {:error, _} =
             lease
             |> Ash.Changeset.for_update(:bind_archive, %{archive_binding_id: second.id})
             |> Ash.update(ctx.opts)

    assert {:ok, retained} = Ash.get(RecordingBlock, lease.id, ctx.opts)
    assert retained.archive_binding_id == first.id

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                pg_code: "23001",
                constraint: "camera_recording_blocks_archive_binding_id_fkey"
              }
            }} =
             Repo.query("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [
               Ecto.UUID.dump!(first.id)
             ])

    assert {:ok, :released} = RecordingBlocks.release_upload(lease, ctx.opts)
    assert {:ok, replacement} = upload(ctx)
    assert replacement.archive_binding_id == first.id
    assert {:error, :upload_lease_lost} = bind(ctx, lease, first)
    assert {:error, :archive_binding_conflict} = bind(ctx, replacement, second)
  end

  test "competing destinations serialize under one current upload handle", ctx do
    bindings = [register_binding(ctx), register_binding(ctx)]
    assert {:ok, _} = freeze(ctx, Fixtures.recording_descriptor(ctx.block))
    assert {:ok, lease} = upload(ctx)
    parent = self()

    tasks =
      for binding <- bindings do
        Task.async(fn ->
          send(parent, :ready)
          receive do: (:go -> bind(ctx, lease, binding))
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :archive_binding_conflict}] = Enum.filter(results, &match?({:error, _}, &1))
    assert {:ok, persisted} = Ash.get(RecordingBlock, lease.id, ctx.opts)
    assert persisted.archive_binding_id == winner.archive_binding_id
    assert persisted.descriptor_sha256 == lease.descriptor_sha256
  end

  defp close_recovery_during_query(ctx, query?, work) do
    handler = {__MODULE__, make_ref()}
    parent = self()
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config ->
          if self() == parent and query?.(metadata.query) do
            File.write!(ctx.recovery.path, String.replace(ctx.recovery.ready, "ready", "closed"))
            send(parent, {:recovery_closed_during_query, handler})
          end
        end,
        nil
      )

    result = work.()
    assert_received {:recovery_closed_during_query, ^handler}
    :ok = :telemetry.detach(handler)
    result
  end

  defp bind(ctx, lease, binding),
    do: RecordingBlocks.bind_archive(lease, binding.id, binding.destination_sha256, ctx.opts)

  defp register_binding(ctx, input \\ Fixtures.archive_destination(Ecto.UUID.generate())) do
    {:ok, binding} = ArchiveBinding.register(input, ctx.opts)
    id = Ecto.UUID.dump!(binding.id)
    source = Ecto.UUID.dump!(ctx.source.id)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1 AND archive_binding_id = $2",
        [source, id]
      )

      Repo.query!("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [id])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $1",
                 [id]
               )
    end)

    binding
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

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
