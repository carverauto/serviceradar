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
  alias ServiceRadar.Camera.RecordingControl
  alias ServiceRadar.Camera.RecordingControlState
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
  @installation %{deployment_ref: "79a7a564-aa29-40ca-8c2b-8cacb9664b6c", generation: 1}

  setup do
    control_owned? = Fixtures.preserve_recording_control(@installation.deployment_ref)
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

    Map.merge(ctx, %{
      block: block,
      lease: lease,
      binding: binding,
      owner: owner,
      claim: claim,
      relay: relay,
      control_owned?: control_owned?
    })
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

  test "stop retains its origin and revision across clients without allowing resume", ctx do
    assert {:ok, %{"stop_enforced" => false, "desired_revision" => nil}} =
             RecordingControl.status(@installation, ctx.opts)

    for opts <- [[], [actor: %{role: :viewer, id: "viewer"}], [actor: %{role: :system}]] do
      assert {:error, :invalid_recording_submitter} =
               RecordingControl.stop(@installation, stop_document(), opts)
    end

    for invalid <- [
          Map.put(stop_document(), "admission", "enabled"),
          Map.put(stop_document(), "admission", "resume"),
          Map.put(stop_document(), "contract_version", 1.0),
          Map.put(stop_document(), "extra", true),
          Map.put(stop_document(), "revision", 1),
          Map.put(stop_document(), "revision", "01"),
          Map.put(stop_document(), "revision", "9223372036854775808")
        ] do
      assert {:error, :invalid_recording_configuration} =
               RecordingControl.stop(@installation, invalid, ctx.opts)
    end

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        RecordingControl.stop(@installation, stop_document(), ctx.opts)

               :checked
             end)

    assert {:ok, first} = RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert first["desired_digest"] ==
             "e60dffcc28624a7f273335d63c93ee8b7759d55ce5ff3a35ba5a4e44a0cadb2e"

    assert %{
             "stop_enforced" => true,
             "desired_revision" => "1",
             "applied_revision" => nil,
             "readiness" => "unavailable",
             "reason" => "recording_stop_only",
             "drain_status" => "not_attested"
           } = first

    assert {:ok, ^first} = RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert {:ok, ^first} =
             fn -> RecordingControl.status(@installation, ctx.opts) end
             |> Task.async()
             |> Task.await()

    # Idempotent baseline initialization cannot clear a durable stop.
    assert {:ok, _} =
             RecordingControlState
             |> Ash.Changeset.for_create(:initialize, %{})
             |> Ash.create(ctx.opts)

    assert {:ok, ^first} = RecordingControl.status(@installation, ctx.opts)
    newer = %{@installation | generation: 2}

    assert {:error, :recording_revision_conflict} =
             RecordingControl.stop(newer, stop_document(), ctx.opts)

    assert {:ok, %{"desired_revision" => "2"}} =
             RecordingControl.stop(newer, stop_document("2"), ctx.opts)

    assert {:error, :recording_revision_stale} =
             RecordingControl.stop(newer, stop_document(), ctx.opts)

    assert {:error, :recording_generation_stale} =
             RecordingControl.stop(@installation, stop_document("3"), ctx.opts)

    assert {:error, :recording_generation_stale} =
             RecordingControl.status(@installation, ctx.opts)

    other = %{newer | deployment_ref: Ecto.UUID.generate()}

    assert {:error, :recording_installation_mismatch} =
             RecordingControl.stop(other, stop_document("3"), ctx.opts)

    assert {:error, :recording_installation_mismatch} = RecordingControl.status(other, ctx.opts)
  end

  test "stop denies new work while frozen media and late dispatch observations remain preservable",
       ctx do
    assert {:ok, _} = bind(ctx)
    assert {:ok, marked} = dispatch(ctx)
    assert {:ok, {:marked, _}} = ArchiveUploads.mark_dispatch(ctx.lease, marked.id, ctx.opts)

    assert {:ok, unsent} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    assert {:ok, open} = RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)

    assert {:ok, %{"stop_enforced" => true}} =
             RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert {:error, :recording_stopped} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )

    assert {:error, :recording_stopped} =
             RecorderOwnership.renew(ctx.owner, ctx.claim, 30_000, ctx.opts)

    assert {:error, :recording_stopped} =
             RecorderOwnership.reserve_block(ctx.owner, ctx.claim, @clock, ctx.opts)

    assert {:error, :recording_stopped} =
             ArchiveUploads.mark_dispatch(ctx.lease, unsent.id, ctx.opts)

    assert {:ok, %{marked_at: nil}} = Ash.get(ArchiveUploadDispatch, unsent.id, ctx.opts)

    assert {:ok, frozen} =
             RecordingBlocks.freeze(ctx.owner, ctx.claim, open, descriptor(open), ctx.opts)

    assert frozen.state == :sealed
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)
    assert {:ok, unknown} = ArchiveUploads.observe_unknown(ctx.lease, marked.id, ctx.opts)
    assert unknown.unknown_at

    assert {:ok, observed} =
             ArchiveUploads.observe_response(
               ctx.lease,
               marked.id,
               %{"status" => 200, "etag" => "synthetic-late-etag"},
               ctx.opts
             )

    assert observed.response["etag"] == "synthetic-late-etag"
    assert observed.marked_at == unknown.marked_at
    assert observed.deadline_at == marked.deadline_at
    assert {:ok, retained} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert retained.descriptor_sha256 == ctx.block.descriptor_sha256
    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)
  end

  test "stop waits for an admitted recorder transaction before acknowledging the restriction",
       ctx do
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)
    parent = self()

    holder =
      database_client(:holder, fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM platform.camera_ingest_owners WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(ctx.owner.id)
          ])

          send(parent, :ingest_locked)

          receive do
            :release_ingest -> :released
          after
            15_000 -> flunk("test ingest lock was not released")
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000
    assert_receive :ingest_locked, 5_000

    admission =
      database_client(:admission, fn ->
        RecorderOwnership.acquire(
          ctx.owner,
          Ecto.UUID.generate(),
          ctx.relay.media_ingest_id,
          Ecto.UUID.generate(),
          30_000,
          ctx.opts
        )
      end)

    assert_receive {:admission, admission_pid}, 5_000
    assert blocked_by?(admission_pid, holder_pid)

    stop =
      database_client(:stop, fn ->
        RecordingControl.stop(@installation, stop_document(), ctx.opts)
      end)

    assert_receive {:stop, stop_pid}, 5_000
    assert blocked_by?(stop_pid, admission_pid)
    stop_ref = stop.ref
    refute_receive {^stop_ref, _result}, 0

    send(holder.pid, :release_ingest)
    assert {:ok, :released} = Task.await(holder, 5_000)
    assert {:ok, admitted} = Task.await(admission, 5_000)
    assert admitted.recorder_epoch > ctx.claim.recorder_epoch
    assert {:ok, %{"stop_enforced" => true}} = Task.await(stop, 5_000)

    assert {:error, :recording_stopped} =
             RecorderOwnership.renew(ctx.owner, admitted, 30_000, ctx.opts)

    assert {:error, :recording_stopped} =
             RecorderOwnership.reserve_block(ctx.owner, admitted, @clock, ctx.opts)
  end

  test "missing singleton initialization serializes stop with competing recorder admission",
       ctx do
    assert {:ok, :released} = RecorderOwnership.release(ctx.owner, ctx.claim, ctx.opts)
    assert ctx.control_owned?, "the first-row race must own the baseline it removes"

    assert %{num_rows: 1} =
             Repo.query!(
               "DELETE FROM platform.camera_recording_control WHERE id = 'deployment' AND NOT stopped"
             )

    results =
      race(fn index ->
        if rem(index, 2) == 0 do
          {:stop, RecordingControl.stop(@installation, stop_document(), ctx.opts)}
        else
          {:acquire,
           RecorderOwnership.acquire(
             ctx.owner,
             Ecto.UUID.generate(),
             ctx.relay.media_ingest_id,
             Ecto.UUID.generate(),
             30_000,
             ctx.opts
           )}
        end
      end)

    stops = for {:stop, {:ok, value}} <- results, do: value
    assert length(stops) == 4
    assert [receipt] = Enum.uniq(stops)
    assert receipt["stop_enforced"]

    for {:acquire, result} <- results do
      assert match?({:ok, _}, result) or
               result in [{:error, :recording_stopped}, {:error, :recorder_already_owned}]
    end

    assert {:ok, ^receipt} = RecordingControl.status(@installation, ctx.opts)
    assert [%{stopped: true}] = Ash.read!(RecordingControlState, ctx.opts)

    assert {:error, :recording_stopped} =
             RecorderOwnership.acquire(
               ctx.owner,
               Ecto.UUID.generate(),
               ctx.relay.media_ingest_id,
               Ecto.UUID.generate(),
               30_000,
               ctx.opts
             )
  end

  defp stop_document(revision \\ "1"),
    do: %{"contract_version" => 1, "revision" => revision, "admission" => "stopped"}

  defp withdrawal(revision),
    do: %{"schema_version" => 1, "revision" => revision, "state" => "withdrawn", "report" => nil}

  defp dispatch(ctx, ttl \\ 30_000),
    do: ArchiveUploads.prepare_dispatch(ctx.lease, :media, :put_object, ttl, ctx.opts)

  defp database_client(tag, fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(
          fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {tag, pid})
            fun.()
          end,
          timeout: 30_000
        )
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    task
  end

  defp blocked_by?(pid, blocker, attempts \\ 500) do
    case Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [pid, blocker]).rows do
      [[true]] ->
        true

      _ when attempts > 0 ->
        Process.sleep(10)
        blocked_by?(pid, blocker, attempts - 1)

      _ ->
        false
    end
  end

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
