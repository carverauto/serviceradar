defmodule ServiceRadar.Camera.RecordingBlocksIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.LocalPublicationIntent
  alias ServiceRadar.Camera.LocalPublicationIntents
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RecordingHolds
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

  test "freeze_and_catalog seals and catalogs in one transaction, retries idempotently, refuses conflicts and missing Core authority, and quarantines unattributable blocks",
       ctx do
    descriptor = Fixtures.recording_descriptor(ctx.block)
    received_at = ~U[2026-11-16 14:00:00.123456Z]

    catalog_attrs = %{
      first_unit_pts: 90_000,
      first_unit_received_at: received_at,
      run_id: "run-synth-01",
      anchor_id: "anchor-synth-01",
      reanchored: true,
      contiguous_with_previous: false
    }

    # Received basis rejects non-nil uncertainty (uncertainty is unmeasured NULL, never 0).
    assert {:error, :invalid_catalog_attributes} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               descriptor,
               Map.put(catalog_attrs, :time_uncertainty_us, 0),
               ctx.opts
             )

    assert {:ok, %RecordingCatalogEntry{} = entry} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               descriptor,
               catalog_attrs,
               ctx.opts
             )

    assert {:ok, sealed_block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert sealed_block.state == :sealed
    assert entry.recording_block_id == sealed_block.id
    assert entry.camera_source_id == ctx.source.id
    assert entry.stream_profile_id == ctx.profile.id
    assert entry.storage_id == ctx.block.storage_id
    assert entry.block_key == ctx.block.block_key
    assert entry.clock_epoch == "invented-clock"
    assert entry.run_id == "run-synth-01"
    assert entry.anchor_id == "anchor-synth-01"
    assert entry.reanchored == true
    assert entry.time_basis == :received
    assert is_nil(entry.time_uncertainty_us)
    assert entry.timeline_start_us == DateTime.to_unix(received_at, :microsecond)
    assert entry.timeline_end_us == entry.timeline_start_us + 1_000_000
    assert entry.media_start_ns == 0
    assert entry.media_end_ns == 1_000_000_000
    assert entry.fragment_count == 1
    assert entry.media_bytes == 3
    assert entry.descriptor_sha256 == sealed_block.descriptor_sha256
    assert entry.local_state == :present
    assert entry.archive_state == :not_required
    assert RecordingCatalogEntry.playable?(entry) == true

    # Exact retry (including second-precision DateTime) returns existing entry idempotently.
    assert {:ok, retry} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               descriptor,
               catalog_attrs,
               ctx.opts
             )

    assert retry.id == entry.id
    assert retry.inserted_at == entry.inserted_at

    # Conflicting descriptor or conflicting catalog attributes are refused without altering state.
    assert {:error, :recording_descriptor_conflict} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               put_in(descriptor["media"]["sha256"], digest("tampered")),
               catalog_attrs,
               ctx.opts
             )

    assert {:error, :recording_descriptor_conflict} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               descriptor,
               Map.put(catalog_attrs, :reanchored, false),
               ctx.opts
             )

    # Reserve a second block, release the recorder claim, and prove missing Core authority
    # cannot freeze or catalog it.
    assert {:ok, unfrozen} =
             RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)

    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)

    assert {:error, :recorder_claim_lost} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               unfrozen,
               Fixtures.recording_descriptor(unfrozen),
               catalog_attrs,
               ctx.opts
             )

    assert {:ok, replacement} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert {:error, :recording_block_mismatch} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               replacement,
               unfrozen,
               Fixtures.recording_descriptor(unfrozen),
               catalog_attrs,
               ctx.opts
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.camera_recording_catalog WHERE block_key = $1",
               [unfrozen.block_key]
             )

    # A block on disk with no Core authority cannot be inserted as local_state = 'present',
    # and can only be cataloged as a never-frozen quarantined entry (never playable).
    unattributed_storage = Ecto.UUID.generate()
    unattributed_key = digest("unattributed-on-disk-block")

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "camera_recording_catalog_sealed_or_quarantined"}
            }} =
             Repo.query(
               """
               INSERT INTO platform.camera_recording_catalog (
                 id, storage_id, block_key, local_state, local_state_at,
                 archive_state, archive_state_at, archive_attempts,
                 reanchored, contiguous_with_previous, inserted_at, updated_at
               ) VALUES (
                 $1, $2, $3, 'present', now(),
                 'not_required', now(), 0,
                 false, false, now(), now()
               )
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 Ecto.UUID.dump!(unattributed_storage),
                 unattributed_key
               ]
             )

    q_receipt = %{
      "partition_path" => ".quarantine/#{unattributed_key}",
      "placed_at_ms" => 1_763_200_500_000,
      "files" => [%{"name" => "media.m4s", "length" => 4096, "sha256" => digest("q-media")}]
    }

    assert {:ok, quarantined} =
             RecordingCatalogEntry.register_quarantined(
               %{
                 storage_id: unattributed_storage,
                 block_key: unattributed_key,
                 quarantine_reason: :unattributable,
                 quarantine_receipt: q_receipt,
                 quarantined_bytes: 4096
               },
               ctx.opts
             )

    q_id_bin = Ecto.UUID.dump!(quarantined.id)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.camera_recording_catalog WHERE id = $1", [q_id_bin])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_recording_catalog WHERE id = $1",
                 [q_id_bin]
               )
    end)

    assert quarantined.local_state == :quarantined
    assert is_nil(quarantined.recording_block_id)
    assert quarantined.quarantine_reason == :unattributable
    assert quarantined.quarantined_bytes == 4096
    assert RecordingCatalogEntry.playable?(quarantined) == false

    # Identical quarantined retry returns retained row; conflicting reason is refused.
    assert {:ok, q_retry} =
             RecordingCatalogEntry.register_quarantined(
               %{
                 storage_id: unattributed_storage,
                 block_key: unattributed_key,
                 quarantine_reason: :unattributable,
                 quarantine_receipt: q_receipt,
                 quarantined_bytes: 4096
               },
               ctx.opts
             )

    assert q_retry.id == quarantined.id

    assert {:error, _} =
             RecordingCatalogEntry.register_quarantined(
               %{
                 storage_id: unattributed_storage,
                 block_key: unattributed_key,
                 quarantine_reason: :unrecoverable_journal,
                 quarantine_receipt: q_receipt,
                 quarantined_bytes: 4096
               },
               ctx.opts
             )

    # Helper for_blocks/2 authorizes settings.recording.view and devices.cameras.recordings.view.
    assert {:error, %Forbidden{}} =
             RecordingCatalogEntry.for_blocks([sealed_block],
               actor: %{id: "no-perm", role: :viewer, permissions: MapSet.new()}
             )

    for perm <- ["settings.recording.view", "devices.cameras.recordings.view"] do
      permitted = %{id: "u-#{perm}", role: :viewer, permissions: MapSet.new([perm])}

      assert {:ok, by_pair} =
               RecordingCatalogEntry.for_blocks([sealed_block, unfrozen], actor: permitted)

      assert Map.keys(by_pair) == [{to_string(sealed_block.storage_id), sealed_block.block_key}]
      assert by_pair[{to_string(sealed_block.storage_id), sealed_block.block_key}].id == entry.id
    end
  end

  test "acquire_upload refuses NVR LocalStorageBinding blocks, terminal-state trigger refuses revival, and RecordingGap enforces single end_us close",
       ctx do
    # 1. B.4: Register an NVR LocalStorageBinding and prove acquire_upload refuses blocks on it.
    nvr_storage_id = Ecto.UUID.generate()

    provisioner =
      :nvr_guard_provisioner
      |> SystemActor.system()
      |> Map.merge(%{nvr_storage_purpose: :provision, nvr_storage_id: nvr_storage_id})

    {:ok, local_binding} =
      LocalStorageBinding.register(
        %{
          "schema_version" => 1,
          "storage_id" => nvr_storage_id,
          "generation" => 1,
          "provider_resource_ref" => "invented-nvr-volume-guard",
          "profile_sha256" => String.duplicate("a", 64)
        },
        actor: provisioner
      )

    lb_id_bin = Ecto.UUID.dump!(local_binding.id)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.camera_local_storage_bindings WHERE id = $1", [lb_id_bin])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_local_storage_bindings WHERE id = $1",
                 [lb_id_bin]
               )
    end)

    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)

    assert {:ok, nvr_claim} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               nvr_storage_id,
               30_000,
               ctx.opts
             )

    assert {:ok, nvr_block} =
             RecorderOwnership.reserve_block(ctx.owner, nvr_claim, @clock, ctx.opts)

    # Even when frozen with plain freeze/5 (before cataloging), LocalStorageBinding blocks are refused.
    nvr_descriptor = Fixtures.recording_descriptor(nvr_block)

    assert {:ok, frozen_nvr} =
             RecordingBlocks.freeze(ctx.owner, nvr_claim, nvr_block, nvr_descriptor, ctx.opts)

    assert {:error, :nvr_local_storage_block} =
             RecordingBlocks.acquire_upload(frozen_nvr.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    # Catalog the block via freeze_and_catalog/6 on the already-frozen NVR block.
    received_at = ~U[2026-11-16 14:10:00.000000Z]

    assert {:ok, catalog_entry} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               nvr_claim,
               nvr_block,
               nvr_descriptor,
               %{first_unit_pts: 0, first_unit_received_at: received_at},
               ctx.opts
             )

    assert {:error, :nvr_local_storage_block} =
             RecordingBlocks.acquire_upload(frozen_nvr.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    # 2. B.1 / C6: PostgreSQL BEFORE UPDATE trigger refuses revival out of reclaimed and deleted.
    now = DateTime.utc_now()

    assert {:ok, reclaimed} =
             catalog_entry
             |> Ash.Changeset.for_update(:transition_local_state, %{
               local_state: :reclaimed,
               local_state_at: now
             })
             |> Ash.update(ctx.opts)

    assert reclaimed.local_state == :reclaimed

    # Ash update out of reclaimed is refused by trigger.
    assert {:error, _} =
             reclaimed
             |> Ash.Changeset.for_update(:transition_local_state, %{
               local_state: :present,
               local_state_at: DateTime.shift(now, second: 1)
             })
             |> Ash.update(ctx.opts)

    # Raw SQL update out of reclaimed is refused by trigger with camera_recording_catalog_local_state_terminal.
    entry_id_bin = Ecto.UUID.dump!(reclaimed.id)

    for target_state <- ["present", "missing", "reclaiming", "quarantined"] do
      assert {:error,
              %Postgrex.Error{
                postgres: %{constraint: "camera_recording_catalog_local_state_terminal"}
              }} =
               Repo.query(
                 "UPDATE platform.camera_recording_catalog SET local_state = $1 WHERE id = $2",
                 [target_state, entry_id_bin]
               )
    end

    # Transitioning archive_state to deleted while local_state stays reclaimed IS allowed.
    assert {:ok, both_terminal} =
             reclaimed
             |> Ash.Changeset.for_update(:transition_archive_state, %{
               archive_state: :deleted,
               archive_state_at: DateTime.shift(now, second: 2),
               archive_deleted_reason: :object_capacity
             })
             |> Ash.update(ctx.opts)

    assert both_terminal.local_state == :reclaimed
    assert both_terminal.archive_state == :deleted
    assert both_terminal.archive_deleted_reason == :object_capacity

    # Ash and raw SQL updates out of deleted are refused by the terminal-state trigger.
    assert {:error, _} =
             both_terminal
             |> Ash.Changeset.for_update(:transition_archive_state, %{
               archive_state: :verified,
               archive_state_at: DateTime.shift(now, second: 3),
               archive_deleted_reason: nil
             })
             |> Ash.update(ctx.opts)

    for target_archive <- ["pending", "verified", "deleting", "missing", "not_required"] do
      assert {:error,
              %Postgrex.Error{
                postgres: %{constraint: "camera_recording_catalog_archive_state_terminal"}
              }} =
               Repo.query(
                 "UPDATE platform.camera_recording_catalog SET archive_state = $1, archive_deleted_reason = NULL WHERE id = $2",
                 [target_archive, entry_id_bin]
               )
    end

    # Idempotent freeze_and_catalog retry on a terminal entry returns it without reviving either copy!
    assert {:ok, terminal_retry} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               nvr_claim,
               nvr_block,
               nvr_descriptor,
               %{first_unit_pts: 0, first_unit_received_at: received_at},
               ctx.opts
             )

    assert terminal_retry.id == both_terminal.id
    assert terminal_retry.local_state == :reclaimed
    assert terminal_retry.archive_state == :deleted

    # 3. B.2: RecordingGap append-only create + single close of end_us >= start_us, no destroy.
    gap_actions =
      RecordingGap
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.sort()

    assert gap_actions == [:create, :read, :update]

    start_us = 1_763_300_000_000_000

    assert {:ok, open_gap} =
             RecordingGap.record(
               %{
                 camera_source_id: ctx.source.id,
                 stream_profile_id: ctx.profile.id,
                 storage_id: nvr_storage_id,
                 run_id: "run-gap-01",
                 clock_epoch: "invented-clock",
                 start_us: start_us,
                 time_basis: :received,
                 reason: :nvr_refused,
                 detail_class: "nvr_inventory_limit"
               },
               ctx.opts
             )

    assert is_nil(open_gap.end_us)

    # Closing with end_us < start_us is refused.
    assert {:error, _} = RecordingGap.close(open_gap, start_us - 1, ctx.opts)

    # Mutating an immutable field on an open gap via SQL is refused by trigger.
    gap_id_bin = Ecto.UUID.dump!(open_gap.id)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "camera_recording_gaps_immutable_fields"}}} =
             Repo.query(
               "UPDATE platform.camera_recording_gaps SET end_us = $1, reason = 'block_absent' WHERE id = $2",
               [start_us + 5_000_000, gap_id_bin]
             )

    # Closing end_us once succeeds.
    assert {:ok, closed_gap} = RecordingGap.close(open_gap, start_us + 5_000_000, ctx.opts)
    assert closed_gap.end_us == start_us + 5_000_000

    # Re-closing via Ash or raw SQL is refused.
    assert {:error, _} = RecordingGap.close(closed_gap, start_us + 9_000_000, ctx.opts)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "camera_recording_gaps_already_closed"}}} =
             Repo.query(
               "UPDATE platform.camera_recording_gaps SET end_us = $1 WHERE id = $2",
               [start_us + 9_000_000, gap_id_bin]
             )
  end

  test "C.2 & C.3: PD5 hold pin moves on archive verification and missing fallback, deletion-first produces unavailable_blocks, and RecordingDisposition trigger refuses UPDATE and DELETE",
       ctx do
    t0 = ~U[2026-11-16 15:00:00.000000Z]
    t0_us = DateTime.to_unix(t0, :microsecond)

    # 1. Catalog block 1 (ctx.block) as local-only (archive_state = :not_required).
    assert {:ok, entry1} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               ctx.block,
               Fixtures.recording_descriptor(ctx.block),
               %{first_unit_pts: 0, first_unit_received_at: t0, policy_storage: :local_only},
               ctx.opts
             )

    assert entry1.local_state == :present
    assert entry1.archive_state == :not_required

    # Authorization guard: actor without devices.cameras.recordings.hold is refused.
    view_only = %{
      id: "viewer-no-hold",
      role: :viewer,
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
    }

    assert {:error, %Forbidden{}} =
             RecordingHolds.place_hold(
               %{
                 camera_source_id: ctx.source.id,
                 start_us: t0_us - 1_000_000,
                 end_us: t0_us + 5_000_000,
                 kind: :investigation,
                 reason: "synthetic unauthorized hold attempt"
               },
               actor: view_only
             )

    hold_actor = %{
      id: "investigator-01",
      role: :admin,
      permissions:
        MapSet.new([
          "devices.view",
          "devices.cameras.recordings.view",
          "devices.cameras.recordings.hold",
          "settings.recording.operate"
        ])
    }

    # Place accepted hold covering entry1: pins :local because archive_state == :not_required.
    assert {:ok, hold1} =
             RecordingHolds.place_hold(
               %{
                 camera_source_id: ctx.source.id,
                 stream_profile_id: ctx.profile.id,
                 start_us: t0_us - 500_000,
                 end_us: t0_us + 2_000_000,
                 kind: :investigation,
                 reason: "preserve synthetic incident timeline"
               },
               actor: hold_actor
             )

    assert hold1.state == :accepted
    assert hold1.unavailable_blocks == []

    assert {:ok, summaries} =
             RecordingHolds.for_catalog_entries([entry1], actor: view_only)

    assert summaries[entry1.id].pinned_copy == :local
    assert summaries[entry1.id].hold_count == 1
    assert summaries[entry1.id].kinds == [:investigation]

    # Local deletion intent on held local-only entry MUST be refused!
    assert {:error, {:blocked_by_hold, %{pinned_copy: :local}}} =
             RecordingHolds.begin_copy_deletion_intent(
               entry1.id,
               :local,
               %{
                 reason: :local_only_overwrite,
                 effective_settings: %{"policy" => "overwrite_oldest"}
               },
               actor: hold_actor
             )

    # 2. Verify archive on entry1 -> pin moves to :archive!
    #    Now :archive deletion intent MUST be refused, while :local eviction MUST be allowed (PD5)!
    binding = register_binding(ctx)

    assert {:ok, %{entry: verified_entry, pinned_copy: :archive, holds: [moved_hold]}} =
             RecordingHolds.mark_archive_verified_and_move_pin(
               entry1.id,
               %{archive_binding_id: binding.id},
               actor: hold_actor
             )

    assert moved_hold.id == hold1.id
    assert verified_entry.archive_state == :verified

    assert {:error, {:blocked_by_hold, %{pinned_copy: :archive}}} =
             RecordingHolds.begin_copy_deletion_intent(
               entry1.id,
               :archive,
               %{reason: :object_capacity, effective_settings: %{"policy" => "reap_oldest"}},
               actor: hold_actor
             )

    # Next, simulate archive copy becoming :missing BEFORE local copy is evicted:
    # pin MUST move back to :local, return affected holds, and refuse :local deletion again!
    assert {:ok,
            %{
              entry: missing_entry,
              pinned_copy: :local,
              holds: [missing_hold],
              held_archive_missing?: true
            }} =
             RecordingHolds.mark_archive_missing_and_fallback_pin(
               entry1.id,
               %{error_class: "object_changed"},
               actor: hold_actor
             )

    assert missing_hold.id == hold1.id
    assert missing_entry.archive_state == :missing

    assert {:error, {:pinned_by_archive_state, :missing}} =
             RecordingHolds.begin_copy_deletion_intent(
               entry1.id,
               :local,
               %{reason: :budget},
               actor: hold_actor
             )

    # Re-verify archive copy -> pin moves to :archive again, and :local budget eviction SUCCEEDS!
    assert {:ok, %{entry: reverified, pinned_copy: :archive}} =
             RecordingHolds.mark_archive_verified_and_move_pin(
               entry1.id,
               %{archive_binding_id: binding.id},
               actor: hold_actor
             )

    assert reverified.archive_state == :verified

    assert {:ok, %{entry: reclaiming_entry, disposition: disp1}} =
             RecordingHolds.begin_copy_deletion_intent(
               entry1.id,
               :local,
               %{
                 reason: :budget,
                 settings_revision: "rev-1",
                 effective_settings: %{"local_high_water_percent" => 90}
               },
               actor: hold_actor
             )

    assert reclaiming_entry.local_state == :reclaiming
    assert disp1.step == :requested
    assert disp1.copy == :local
    assert disp1.reason == :budget
    assert disp1.hold_check_result["decision"] == "allowed_local_eviction_archive_pinned"

    # Append follow-up step (:executed) under the same operation_id.
    assert {:ok, disp_exec} =
             RecordingHolds.record_disposition_step(disp1, :executed, %{}, actor: hold_actor)

    assert disp_exec.operation_id == disp1.operation_id
    assert disp_exec.step == :executed

    # PostgreSQL BEFORE UPDATE OR DELETE trigger on camera_recording_dispositions refuses UPDATE and DELETE!
    disp_id_bin = Ecto.UUID.dump!(disp1.id)

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "camera_recording_dispositions_append_only"}
            }} =
             Repo.query(
               "UPDATE platform.camera_recording_dispositions SET reason = 'max_local_age' WHERE id = $1",
               [disp_id_bin]
             )

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "camera_recording_dispositions_append_only"}
            }} =
             Repo.query(
               "DELETE FROM platform.camera_recording_dispositions WHERE id = $1",
               [disp_id_bin]
             )

    # Check constraint requires catalog_entry_id IS NOT NULL for catalog-bound reasons,
    # while allowing operator_quarantine with catalog_entry_id: nil for non-catalog residue.
    assert {:error, _} =
             RecordingDisposition.record(
               %{
                 operation_id: Ecto.UUID.generate(),
                 catalog_entry_id: nil,
                 storage_id: ctx.claim.storage_id,
                 block_key: digest("non-catalog-invalid-reason"),
                 copy: :local,
                 reason: :budget,
                 step: :requested,
                 actor_id: "system"
               },
               ctx.opts
             )

    residue_op = Ecto.UUID.generate()
    on_exit(fn -> Fixtures.cleanup_dispositions_by_operation(residue_op) end)

    assert {:ok, residue_disp} =
             RecordingDisposition.record(
               %{
                 operation_id: residue_op,
                 catalog_entry_id: nil,
                 storage_id: ctx.claim.storage_id,
                 block_key: digest("non-catalog-quarantine-residue"),
                 copy: :local,
                 reason: :operator_quarantine,
                 step: :requested,
                 actor_id: "investigator-01"
               },
               ctx.opts
             )

    assert is_nil(residue_disp.catalog_entry_id)

    # 3. Deletion intent committed FIRST wins: subsequent place_hold records unavailable_blocks!
    t2 = DateTime.shift(t0, second: 30)
    t2_us = DateTime.to_unix(t2, :microsecond)

    assert {:ok, block2} =
             RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)

    assert {:ok, entry2} =
             RecordingBlocks.freeze_and_catalog(
               ctx.owner,
               ctx.claim,
               block2,
               Fixtures.recording_descriptor(block2),
               %{
                 first_unit_pts: 2_700_000,
                 first_unit_received_at: t2,
                 policy_storage: :local_only
               },
               ctx.opts
             )

    assert {:ok, %{entry: entry2_reclaiming}} =
             RecordingHolds.begin_copy_deletion_intent(
               entry2.id,
               :local,
               %{reason: :local_only_overwrite},
               actor: hold_actor
             )

    assert entry2_reclaiming.local_state == :reclaiming

    assert {:ok, hold_after_delete} =
             RecordingHolds.place_hold(
               %{
                 camera_source_id: ctx.source.id,
                 start_us: t2_us - 100_000,
                 end_us: t2_us + 2_000_000,
                 kind: :export,
                 reason: "export request after deletion started"
               },
               actor: hold_actor
             )

    assert [
             %{
               "catalog_entry_id" => unavail_id,
               "status" => "unavailable, deletion in progress"
             }
           ] = hold_after_delete.unavailable_blocks

    assert unavail_id == entry2.id

    # Hold never claims to protect a block listed in unavailable_blocks!
    assert {:ok, after_summaries} =
             RecordingHolds.for_catalog_entries([entry2_reclaiming], actor: view_only)

    assert after_summaries[entry2.id].hold_count == 0
    assert is_nil(after_summaries[entry2.id].pinned_copy)

    # Release hold1 explicitly and verify re-release is refused.
    assert {:ok, released_hold} =
             RecordingHolds.release_hold(
               hold1.id,
               %{release_reason: "investigation closed"},
               actor: hold_actor
             )

    assert released_hold.state == :released
    assert released_hold.released_by_id == "investigator-01"
    assert released_hold.release_reason == "investigation closed"

    assert {:error, :hold_already_released} =
             RecordingHolds.release_hold(hold1.id, %{}, actor: hold_actor)
  end

  test "C.2 & C.12: concurrent Task.async row-lock serialization prevents hold-pinning and deletion-intent from both succeeding on a single copy",
       ctx do
    hold_actor = %{
      id: "race-investigator",
      role: :admin,
      permissions:
        MapSet.new([
          "devices.view",
          "devices.cameras.recordings.hold",
          "settings.recording.operate"
        ])
    }

    base_t = ~U[2026-11-16 15:30:00.000000Z]

    # Run 6 independent races on distinct single-copy local-only catalog entries across
    # concurrent DB connections synchronized on a start barrier.
    for round <- 1..6 do
      block =
        if round == 1 do
          ctx.block
        else
          {:ok, b} = RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)
          b
        end

      ts = DateTime.shift(base_t, second: round * 20)
      ts_us = DateTime.to_unix(ts, :microsecond)

      assert {:ok, entry} =
               RecordingBlocks.freeze_and_catalog(
                 ctx.owner,
                 ctx.claim,
                 block,
                 Fixtures.recording_descriptor(block),
                 %{
                   first_unit_pts: round * 900_000,
                   first_unit_received_at: ts,
                   policy_storage: :local_only
                 },
                 ctx.opts
               )

      parent = self()

      hold_task =
        Task.async(fn ->
          send(parent, {:hold_ready, self()})
          receive do: (:go -> :ok)

          RecordingHolds.place_hold(
            %{
              camera_source_id: ctx.source.id,
              stream_profile_id: ctx.profile.id,
              start_us: ts_us - 50_000,
              end_us: ts_us + 2_000_000,
              kind: :investigation,
              reason: "concurrent hold round #{round}"
            },
            actor: hold_actor
          )
        end)

      delete_task =
        Task.async(fn ->
          send(parent, {:delete_ready, self()})
          receive do: (:go -> :ok)

          RecordingHolds.begin_copy_deletion_intent(
            entry.id,
            :local,
            %{reason: :local_only_overwrite},
            actor: hold_actor
          )
        end)

      assert_receive {:hold_ready, hold_pid}, 5_000
      assert_receive {:delete_ready, delete_pid}, 5_000

      if rem(round, 2) == 0 do
        send(hold_pid, :go)
        send(delete_pid, :go)
      else
        send(delete_pid, :go)
        send(hold_pid, :go)
      end

      assert {:ok, %RecordingHold{} = hold} = Task.await(hold_task, 10_000)
      delete_result = Task.await(delete_task, 10_000)

      {:ok, refreshed} = Ash.get(RecordingCatalogEntry, entry.id, ctx.opts)

      case delete_result do
        {:error, {:blocked_by_hold, %{pinned_copy: :local}}} ->
          # Hold committed first -> deletion intent was refused and local copy stayed :present!
          assert hold.unavailable_blocks == []
          assert refreshed.local_state == :present

        {:ok, %{entry: %{local_state: :reclaiming}}} ->
          # Deletion intent committed first -> hold MUST record the block as unavailable!
          assert refreshed.local_state == :reclaiming

          assert [
                   %{
                     "catalog_entry_id" => unavail_id,
                     "status" => "unavailable, deletion in progress"
                   }
                 ] = hold.unavailable_blocks

          assert unavail_id == entry.id

        other ->
          flunk("unexpected concurrent deletion result: #{inspect(other)}")
      end
    end
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
        """
        UPDATE platform.camera_recording_catalog
        SET archive_binding_id = NULL, quarantine_binding_id = NULL
        WHERE archive_binding_id = $1 OR quarantine_binding_id = $1
        """,
        [id]
      )

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
