defmodule ServiceRadar.Camera.ArchiveUploadsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveQualificationReceipt
  alias ServiceRadar.Camera.ArchiveQualifications
  alias ServiceRadar.Camera.ArchiveUploadDispatch
  alias ServiceRadar.Camera.ArchiveUploadIntent
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  require Ash.Query

  @clock %{
    "clock_epoch" => "invented-upload-clock",
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
    {:ok, block} = RecordingBlocks.freeze(owner, claim, block, descriptor(block), ctx.opts)

    {:ok, lease} =
      RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    {:ok, binding} =
      ArchiveBinding.register(Fixtures.archive_destination(Ecto.UUID.generate()), ctx.opts)

    block_id = Ecto.UUID.dump!(block.id)
    binding_id = Ecto.UUID.dump!(binding.id)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
        [binding_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
                 [binding_id]
               )

      %{rows: dispatch_ids} =
        Repo.query!(
          "DELETE FROM platform.camera_archive_upload_dispatches WHERE archive_upload_intent_id IN " <>
            "(SELECT id FROM platform.camera_archive_upload_intents WHERE recording_block_id = $1) RETURNING id",
          [block_id]
        )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_upload_dispatches WHERE id = ANY($1::uuid[])",
                 [List.flatten(dispatch_ids)]
               )

      Repo.query!(
        "DELETE FROM platform.camera_archive_upload_intents WHERE recording_block_id = $1",
        [block_id]
      )

      Repo.query!("DELETE FROM platform.camera_recording_blocks WHERE id = $1", [block_id])
      Repo.query!("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [binding_id])

      assert %{rows: [[0, 0, 0]]} =
               Repo.query!(
                 "SELECT (SELECT count(*) FROM platform.camera_archive_upload_intents WHERE recording_block_id = $1), " <>
                   "(SELECT count(*) FROM platform.camera_recording_blocks WHERE id = $1), " <>
                   "(SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $2)",
                 [block_id, binding_id]
               )
    end)

    Map.merge(ctx, %{block: block, lease: lease, binding: binding})
  end

  test "preparation retains derived object identity across upload lease replacement", ctx do
    bind(ctx)
    assert {:ok, init} = ArchiveUploads.prepare(ctx.lease, :init, ctx.opts)
    assert {:ok, media} = ArchiveUploads.prepare(ctx.lease, :media, ctx.opts)
    assert init.id != media.id
    assert init.byte_length == 1 and init.object_sha256 == digest("i")
    assert media.byte_length == 3 and media.object_sha256 == digest("abc")
    assert init.object_key == "recordings/v1/#{ctx.block.block_key}/init.mp4"
    assert media.object_key == "recordings/v1/#{ctx.block.block_key}/media.m4s"

    for intent <- [init, media] do
      assert intent.recording_block_id == ctx.block.id
      assert intent.archive_binding_id == ctx.binding.id
      assert intent.descriptor_sha256 == ctx.block.descriptor_sha256
      assert intent.destination_sha256 == ctx.binding.destination_sha256
      assert intent.schema_version == 1
    end

    assert {:ok, retry} = ArchiveUploads.prepare(ctx.lease, :media, ctx.opts)
    assert persisted_identity(retry) == persisted_identity(media)
    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)
    assert {:error, :upload_lease_lost} = ArchiveUploads.prepare(ctx.lease, :media, ctx.opts)

    assert {:ok, replacement} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:ok, retained} = ArchiveUploads.prepare(replacement, :media, ctx.opts)
    assert persisted_identity(retained) == persisted_identity(media)
    assert {:ok, %{state: :uploading}} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)

    assert {:ok, %{capability_state: :unqualified}} =
             Ash.get(ArchiveBinding, ctx.binding.id, ctx.opts)
  end

  test "unbound blocks, unsupported roles, expired handles and viewers cannot prepare", ctx do
    assert {:error, :archive_binding_required} =
             ArchiveUploads.prepare(ctx.lease, :init, ctx.opts)

    bind(ctx)
    assert {:error, :invalid_object_role} = ArchiveUploads.prepare(ctx.lease, :manifest, ctx.opts)
    assert {:error, _} = ArchiveUploads.prepare(ctx.lease, :init, actor: %{role: :viewer})

    assert {:error, :upload_lease_lost} =
             ArchiveUploads.prepare(
               %{ctx.lease | descriptor_sha256: digest("substituted")},
               :init,
               ctx.opts
             )

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, short} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 2_000, ctx.opts)

    Process.sleep(2_100)
    assert {:error, :upload_lease_lost} = ArchiveUploads.prepare(short, :init, ctx.opts)
    assert [] = intents(ctx)
  end

  test "concurrent retries retain one intent and prevent deletion of its block", ctx do
    bind(ctx)
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, :ready)
          receive do: (:go -> ArchiveUploads.prepare(ctx.lease, :media, ctx.opts))
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    ids =
      Enum.map(tasks, fn task ->
        assert {:ok, intent} = Task.await(task, 10_000)
        intent.id
      end)

    assert [id] = Enum.uniq(ids)
    assert [%{id: ^id}] = intents(ctx)

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                pg_code: "23001",
                constraint: "camera_archive_upload_intents_recording_block_id_fkey"
              }
            }} =
             Repo.query("DELETE FROM platform.camera_recording_blocks WHERE id = $1", [
               Ecto.UUID.dump!(ctx.block.id)
             ])

    assert [%{id: ^id}] = intents(ctx)
    assert {:ok, %{id: block_id}} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert block_id == ctx.block.id
  end

  test "an ambient transaction is rejected before preparation writes", ctx do
    bind(ctx)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        ArchiveUploads.prepare(ctx.lease, :init, ctx.opts)

               assert [] = intents(ctx)
               :checked
             end)

    assert [] = intents(ctx)
    assert {:ok, _} = ArchiveUploads.prepare(ctx.lease, :init, ctx.opts)
  end

  test "a conflicting retained intent is refused without replacing its evidence", ctx do
    bind(ctx)

    # The trusted persistence primitive can expose a caller bug. Preparation
    # must compare the retained content rather than bless any unique-key match.
    assert {:ok, conflicting} =
             ArchiveUploadIntent
             |> Ash.Changeset.for_create(:prepare, %{
               recording_block_id: ctx.block.id,
               archive_binding_id: ctx.binding.id,
               descriptor_sha256: ctx.block.descriptor_sha256,
               destination_sha256: ctx.binding.destination_sha256,
               object_role: :init,
               object_key: "recordings/v1/#{ctx.block.block_key}/init.mp4",
               byte_length: 1,
               object_sha256: digest("different")
             })
             |> Ash.create(ctx.opts)

    assert {:error, :archive_upload_intent_conflict} =
             ArchiveUploads.prepare(ctx.lease, :init, ctx.opts)

    assert {:error, :archive_upload_intent_conflict} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    assert [] = dispatches(ctx)

    assert [retained] = intents(ctx)
    assert persisted_identity(retained) == persisted_identity(conflicting)
  end

  test "dispatch identity and its original deadline survive retries but cannot be rearmed", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx)
    assert [intent] = intents(ctx)
    assert dispatch.archive_upload_intent_id == intent.id
    assert dispatch.upload_epoch == ctx.lease.upload_epoch
    assert dispatch.upload_token_sha256 == digest(ctx.lease.upload_token)
    assert dispatch.dispatcher_actor_id == ctx.actor.id
    assert dispatch.operation == :put_object
    assert byte_size(dispatch.request_sha256) == 64
    assert DateTime.compare(dispatch.deadline_at, ctx.lease.upload_expires_at) in [:lt, :eq]
    assert is_nil(dispatch.marked_at)

    assert {:ok, _renewed} = RecordingBlocks.renew_upload(ctx.lease, 300_000, ctx.opts)

    assert {:ok, retry} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :media, :put_object, 300_000, ctx.opts)

    assert dispatch_identity(retry) == dispatch_identity(dispatch)

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.prepare_dispatch(
               ctx.lease,
               :media,
               :create_multipart_upload,
               30_000,
               ctx.opts
             )

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, replacement} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.prepare_dispatch(replacement, :media, :put_object, 30_000, ctx.opts)

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.mark_dispatch(replacement, dispatch.id, ctx.opts)

    assert [retained] = dispatches(ctx)
    assert dispatch_identity(retained) == dispatch_identity(dispatch)
    assert is_nil(retained.marked_at)
  end

  test "concurrent preparation and marking commit one attempt and one fresh marker", ctx do
    bind(ctx)
    attempts = race(fn -> dispatch(ctx) end)
    assert Enum.all?(attempts, &match?({:ok, %ArchiveUploadDispatch{}}, &1))
    assert [id] = attempts |> Enum.map(fn {:ok, d} -> d.id end) |> Enum.uniq()

    results = race(fn -> ArchiveUploads.mark_dispatch(ctx.lease, id, ctx.opts) end)
    assert [{:ok, {:marked, marked}}] = Enum.filter(results, &match?({:ok, {:marked, _}}, &1))
    assert Enum.count(results, &match?({:ok, {:already_marked, _}}, &1)) == 7
    assert [retained] = dispatches(ctx)
    assert retained.id == id and retained.marked_at == marked.marked_at

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM platform.camera_archive_upload_intents WHERE id = $1", [
               Ecto.UUID.dump!(retained.archive_upload_intent_id)
             ])

    assert [%{id: ^id}] = dispatches(ctx)
    assert [intent] = intents(ctx)
    assert intent.id == retained.archive_upload_intent_id
    assert {:ok, %{state: :uploading}} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)

    assert {:ok, %{capability_state: :unqualified}} =
             Ash.get(ArchiveBinding, ctx.binding.id, ctx.opts)
  end

  test "renewal cannot extend the prepared operation deadline", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx, 2_000)
    assert {:ok, _} = RecordingBlocks.renew_upload(ctx.lease, 30_000, ctx.opts)
    Process.sleep(2_100)

    assert {:error, :upload_dispatch_expired} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    assert {:ok, retry} = dispatch(ctx, 30_000)
    assert dispatch_identity(retry) == dispatch_identity(dispatch)
    assert is_nil(retry.marked_at)
    assert :ok = RecordingBlocks.with_current_upload(ctx.lease, fn _ -> :ok end, ctx.opts)
  end

  test "invalid preparation and wrong actors cannot create or mark attempts", ctx do
    bind(ctx)

    for actor <- [%{role: :viewer, id: "reader"}, %{role: :system}, %{role: :system, id: ""}] do
      assert {:error, :invalid_dispatcher} =
               ArchiveUploads.prepare_dispatch(ctx.lease, :media, :put_object, 30_000,
                 actor: actor
               )
    end

    assert {:error, :invalid_object_role} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :manifest, :put_object, 30_000, ctx.opts)

    assert {:error, :invalid_upload_operation} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :media, :delete_object, 30_000, ctx.opts)

    assert {:error, :invalid_ttl} = dispatch(ctx, 300_001)
    assert [] = intents(ctx)
    assert [] = dispatches(ctx)
    assert {:ok, dispatch} = dispatch(ctx)
    other = Keyword.put(ctx.opts, :actor, %{role: :system, id: "system:another_dispatcher"})

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, other)

    assert {:error, :upload_lease_lost} =
             ArchiveUploads.mark_dispatch(
               %{ctx.lease | descriptor_sha256: digest("forged")},
               dispatch.id,
               ctx.opts
             )

    assert {:error, :upload_dispatch_unmarked} =
             ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)

    assert {:error, :upload_dispatch_unmarked} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, %{"status" => 200}, ctx.opts)

    assert [retained] = dispatches(ctx)

    assert is_nil(retained.marked_at) and is_nil(retained.unknown_at) and
             is_nil(retained.response_at)
  end

  test "all dispatch mutations reject ambient transactions before writing", ctx do
    bind(ctx)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} = dispatch(ctx)
               assert [] = intents(ctx)
               assert [] = dispatches(ctx)
               :checked
             end)

    assert {:ok, dispatch} = dispatch(ctx)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.observe_response(
                          ctx.lease,
                          dispatch.id,
                          %{"status" => 200},
                          ctx.opts
                        )

               :checked
             end)

    assert [retained] = dispatches(ctx)

    assert is_nil(retained.marked_at) and is_nil(retained.unknown_at) and
             is_nil(retained.response_at)
  end

  test "missing dispatches return the same error for marking and observations", ctx do
    missing = Ecto.UUID.generate()

    assert {:error, :upload_dispatch_not_found} =
             ArchiveUploads.mark_dispatch(ctx.lease, missing, ctx.opts)

    assert {:error, :upload_dispatch_not_found} =
             ArchiveUploads.observe_unknown(ctx.lease, missing, ctx.opts)

    assert {:error, :upload_dispatch_not_found} =
             ArchiveUploads.observe_response(ctx.lease, missing, %{"status" => 200}, ctx.opts)

    assert [] = dispatches(ctx)
  end

  test "late unknown and receipt races retain both facts after lease replacement", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx)

    assert {:ok, {:marked, marked}} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, replacement} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    response = %{"status" => 200, "etag" => "invented-etag", "version_id" => "invented-version"}

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.observe_response(replacement, dispatch.id, response, ctx.opts)

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.observe_unknown(ctx.lease, dispatch.id,
               actor: %{role: :system, id: "system:another_dispatcher"}
             )

    results =
      race(fn index ->
        if rem(index, 2) == 0,
          do: ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts),
          else: ArchiveUploads.observe_response(ctx.lease, dispatch.id, response, ctx.opts)
      end)

    assert Enum.all?(results, &match?({:ok, %ArchiveUploadDispatch{}}, &1))
    assert [retained] = dispatches(ctx)
    assert retained.marked_at == marked.marked_at
    assert retained.unknown_at != nil and retained.response_at != nil
    assert retained.response == response and is_nil(retained.conflict_at)
    assert {:ok, block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)

    assert block.upload_epoch == replacement.upload_epoch and
             block.upload_token == replacement.upload_token

    assert block.state == :uploading

    assert {:error, :upload_lease_lost} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)
  end

  test "a conflicting receipt commits permanent evidence and preserves the first receipt", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx)
    assert {:ok, {:marked, _}} = ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)
    first = %{"status" => 200, "etag" => "invented-first"}
    second = %{"status" => 503, "request_id" => "invented-second"}

    assert {:ok, original} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, first, ctx.opts)

    assert {:ok, retry} = ArchiveUploads.observe_response(ctx.lease, dispatch.id, first, ctx.opts)
    assert retry.response_at == original.response_at

    assert {:error, :archive_upload_response_conflict} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, second, ctx.opts)

    assert [conflict] = dispatches(ctx)
    assert conflict.response == first and conflict.response_sha256 == original.response_sha256
    assert conflict.response_at == original.response_at and conflict.conflict_at != nil
    assert conflict.first_conflict_sha256 != original.response_sha256

    assert conflict.first_conflict_sha256 ==
             "28d045054527d841f571f04f3b00c1ea79ad1bc12772f9568b1ce40d737399ec"

    assert {:error, :archive_upload_response_conflict} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, first, ctx.opts)

    assert {:ok, unknown} = ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)
    assert unknown.conflict_at == conflict.conflict_at and unknown.unknown_at != nil
    assert unknown.first_conflict_sha256 == conflict.first_conflict_sha256
  end

  test "competing different responses retain exactly one receipt and permanent conflict", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx)
    assert {:ok, {:marked, _}} = ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    results =
      race(fn index ->
        ArchiveUploads.observe_response(
          ctx.lease,
          dispatch.id,
          %{"status" => 200, "etag" => "invented-#{index}"},
          ctx.opts
        )
      end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :archive_upload_response_conflict})) == 7
    assert [retained] = dispatches(ctx)
    assert retained.response == winner.response and retained.response_at == winner.response_at

    assert is_binary(retained.first_conflict_sha256) and
             byte_size(retained.first_conflict_sha256) == 64

    assert retained.conflict_at != nil and
             retained.first_conflict_sha256 != retained.response_sha256
  end

  test "marking rederives every retained intent field before committing its marker", ctx do
    bind(ctx)
    assert {:ok, dispatch} = dispatch(ctx)
    assert [intent] = intents(ctx)
    substituted = digest("invented-corruption")

    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE platform.camera_archive_upload_intents SET object_sha256 = $1 WHERE id = $2",
               [substituted, Ecto.UUID.dump!(intent.id)]
             )

    assert {:error, :archive_upload_intent_conflict} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    assert [retained] = dispatches(ctx)
    assert is_nil(retained.marked_at)
    assert [retained_intent] = intents(ctx)
    assert retained_intent.object_sha256 == substituted
  end

  test "multipart observations require bounded receipts and cannot recover a lost upload id",
       ctx do
    bind(ctx)

    assert {:ok, dispatch} =
             ArchiveUploads.prepare_dispatch(
               ctx.lease,
               :media,
               :create_multipart_upload,
               30_000,
               ctx.opts
             )

    assert {:ok, {:marked, _}} = ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    for response <- [
          %{"status" => 200},
          %{"status" => 200, "upload_id" => ""},
          %{"status" => 200, "upload_id" => String.duplicate("x", 1025)},
          %{"status" => 200, "upload_id" => "invented", "headers" => %{}},
          %{"status" => 200, "upload_id" => "invented\nheader"},
          %{status: 200},
          %{"status" => 100}
        ] do
      assert {:error, :invalid_upload_response} =
               ArchiveUploads.observe_response(ctx.lease, dispatch.id, response, ctx.opts)
    end

    assert [empty] = dispatches(ctx)
    assert is_nil(empty.response_at) and is_nil(empty.conflict_at)
    assert {:ok, unknown} = ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)
    assert unknown.unknown_at != nil and is_nil(unknown.response)

    assert {:ok, {:already_marked, _}} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    response = %{"status" => 200, "upload_id" => "invented+opaque/id~="}

    assert {:ok, late} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, response, ctx.opts)

    assert late.response == response and late.unknown_at == unknown.unknown_at
  end

  test "qualification receipt retries and competing revisions serialize on the retained binding",
       ctx do
    first = withdrawal(1)
    results = race(fn _ -> ArchiveQualifications.submit(ctx.binding.id, first, ctx.opts) end)

    receipts =
      Enum.map(results, fn result ->
        assert {:ok, %{revision: 1, state: :withdrawn, report: nil, report_sha256: nil} = receipt} =
                 result

        receipt
      end)

    binding_id = ctx.binding.id
    assert [^binding_id] = receipts |> Enum.map(& &1.archive_binding_id) |> Enum.uniq()
    assert [_received_at] = receipts |> Enum.map(& &1.received_at) |> Enum.uniq()

    assert {:ok, %{archive_binding_id: ^binding_id, revision: 1} = received} =
             ArchiveQualifications.status(ctx.binding.id, ctx.opts)

    # Literal protocol bytes are independent of the production JSON encoder.
    expected_bytes = ~s(["archive-qualification-v1","#{binding_id}",1,"withdrawn",null])
    assert received.receipt_sha256 == digest(expected_bytes)

    results =
      race(fn index ->
        revision = index + 1
        {revision, ArchiveQualifications.submit(ctx.binding.id, withdrawal(revision), ctx.opts)}
      end)

    for {revision, result} <- results do
      case result do
        {:ok, receipt} ->
          assert receipt.archive_binding_id == binding_id and receipt.revision == revision

        {:error, reason} ->
          assert reason == :qualification_revision_stale
      end
    end

    assert {:ok, %{archive_binding_id: ^binding_id, revision: 9, state: :withdrawn}} =
             ArchiveQualifications.status(ctx.binding.id, ctx.opts)

    assert [%{archive_binding_id: ^binding_id}] =
             ArchiveQualificationReceipt
             |> Ash.Query.filter(archive_binding_id == ^ctx.binding.id)
             |> Ash.read!(ctx.opts)

    assert {:ok, %{capability_state: :unqualified}} =
             Ash.get(ArchiveBinding, ctx.binding.id, ctx.opts)
  end

  test "qualification receipt rejects invalid callers and input before writing", ctx do
    for opts <- [
          [],
          [actor: %{role: :viewer, id: "viewer"}],
          [actor: %{role: :system}],
          [actor: %{role: :system, id: " "}]
        ] do
      assert {:error, :invalid_qualification_submitter} =
               ArchiveQualifications.submit(ctx.binding.id, withdrawal(1), opts)

      assert {:error, :invalid_qualification_submitter} =
               ArchiveQualifications.status(ctx.binding.id, opts)
    end

    for id <- [nil, 1, "invalid", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"] do
      assert {:error, :invalid_archive_binding_id} =
               ArchiveQualifications.submit(id, withdrawal(1), ctx.opts)

      assert {:error, :invalid_archive_binding_id} = ArchiveQualifications.status(id, ctx.opts)
    end

    for input <- [
          nil,
          Map.delete(withdrawal(1), "report"),
          Map.put(withdrawal(1), "unexpected", true),
          Map.put(withdrawal(1), "schema_version", 2),
          Map.put(withdrawal(1), "state", "applied"),
          Map.put(withdrawal(1), "report", %{}),
          Map.put(withdrawal(1), "revision", 0),
          Map.put(withdrawal(1), "revision", 1.0),
          Map.put(withdrawal(1), "revision", 9_223_372_036_854_775_808)
        ] do
      assert {:error, :invalid_qualification_submission} =
               ArchiveQualifications.submit(ctx.binding.id, input, ctx.opts)
    end

    missing_id = Ecto.UUID.generate()

    assert {:error, :archive_binding_not_found} =
             ArchiveQualifications.submit(missing_id, withdrawal(1), ctx.opts)

    assert {:error, :archive_binding_not_found} =
             ArchiveQualifications.status(missing_id, ctx.opts)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        ArchiveQualifications.submit(ctx.binding.id, withdrawal(1), ctx.opts)

               :checked
             end)

    assert {:ok, nil} = ArchiveQualifications.status(ctx.binding.id, ctx.opts)
  end

  test "withdrawal preserves the binding reference and revision high-water", ctx do
    assert {:ok, receipt} = ArchiveQualifications.submit(ctx.binding.id, withdrawal(2), ctx.opts)

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                constraint: "camera_archive_qualification_receipts_archive_binding_id_fkey"
              }
            }} =
             Repo.query("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [
               Ecto.UUID.dump!(ctx.binding.id)
             ])

    assert {:error, :qualification_revision_stale} =
             ArchiveQualifications.submit(ctx.binding.id, withdrawal(1), ctx.opts)

    assert {:ok, retained} = ArchiveQualifications.status(ctx.binding.id, ctx.opts)

    assert retained.archive_binding_id == receipt.archive_binding_id and
             retained.receipt_sha256 == receipt.receipt_sha256

    assert retained.received_at == receipt.received_at and retained.revision == 2
  end

  defp withdrawal(revision),
    do: %{"schema_version" => 1, "revision" => revision, "state" => "withdrawn", "report" => nil}

  defp dispatch(ctx, ttl \\ 30_000),
    do: ArchiveUploads.prepare_dispatch(ctx.lease, :media, :put_object, ttl, ctx.opts)

  defp dispatches(ctx) do
    ids = Enum.map(intents(ctx), & &1.id)

    ArchiveUploadDispatch
    |> Ash.Query.filter(archive_upload_intent_id in ^ids)
    |> Ash.read!(ctx.opts)
  end

  defp dispatch_identity(dispatch) do
    Map.take(dispatch, [
      :id,
      :archive_upload_intent_id,
      :upload_epoch,
      :upload_token_sha256,
      :dispatcher_actor_id,
      :operation,
      :request_sha256,
      :prepared_at,
      :deadline_at
    ])
  end

  defp race(fun) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          send(parent, :ready)

          receive do
            :go -> if is_function(fun, 1), do: fun.(index), else: fun.()
          end
        end)
      end

    for _ <- tasks, do: assert_receive(:ready, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp bind(ctx) do
    assert {:ok, _} =
             RecordingBlocks.bind_archive(
               ctx.lease,
               ctx.binding.id,
               ctx.binding.destination_sha256,
               ctx.opts
             )
  end

  defp intents(ctx) do
    ArchiveUploadIntent
    |> Ash.Query.filter(recording_block_id == ^ctx.block.id)
    |> Ash.read!(ctx.opts)
  end

  defp persisted_identity(intent) do
    Map.take(intent, [
      :id,
      :schema_version,
      :recording_block_id,
      :archive_binding_id,
      :descriptor_sha256,
      :destination_sha256,
      :object_role,
      :object_key,
      :byte_length,
      :object_sha256,
      :inserted_at
    ])
  end

  # Invented bytes describe this authority test; existing media keepers own decoding.
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
