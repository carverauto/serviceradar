defmodule ServiceRadar.Camera.ArchiveUploadsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ArchiveAuthorities
  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveInitAuthority
  alias ServiceRadar.Camera.ArchiveManifestAuthority
  alias ServiceRadar.Camera.ArchiveMediaAuthority
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
  alias ServiceRadar.Camera.RecordingManifest
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
        "DELETE FROM platform.camera_archive_manifest_authorities WHERE archive_binding_id = $1",
        [binding_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_manifest_authorities WHERE archive_binding_id = $1",
                 [binding_id]
               )

      Repo.query!(
        "DELETE FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $1",
        [binding_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $1",
                 [binding_id]
               )

      Repo.query!(
        "DELETE FROM platform.camera_archive_init_authorities WHERE archive_binding_id = $1",
        [binding_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_init_authorities WHERE archive_binding_id = $1",
                 [binding_id]
               )

      Repo.query!(
        "DELETE FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
        [binding_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
                 [binding_id]
               )

      Repo.query!(
        "UPDATE platform.camera_recording_blocks SET archive_manifest_dispatch_id = NULL, " <>
          "archive_manifest_verification_sha256 = NULL, archive_published_at = NULL WHERE id = $1",
        [block_id]
      )

      %{rows: manifest_dispatch_ids} =
        Repo.query!(
          "DELETE FROM platform.camera_archive_upload_dispatches WHERE archive_upload_intent_id IN " <>
            "(SELECT id FROM platform.camera_archive_upload_intents " <>
            "WHERE recording_block_id = $1 AND object_role = 'manifest') RETURNING id",
          [block_id]
        )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_upload_dispatches WHERE id = ANY($1::uuid[])",
                 [List.flatten(manifest_dispatch_ids)]
               )

      Repo.query!(
        "DELETE FROM platform.camera_archive_upload_intents WHERE recording_block_id = $1 AND object_role = 'manifest'",
        [block_id]
      )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_upload_intents " <>
                   "WHERE recording_block_id = $1 AND object_role = 'manifest'",
                 [block_id]
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

    assert {:ok, %{status: :reconciliation_required, roles: %{media: :prepared}, result: nil}} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:error, :archive_dependencies_unverified} =
             ArchiveUploads.prepare_manifest(replacement, ctx.opts)
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

  test "init authority retains its original window and consumes revisions before application",
       ctx do
    {principal, desired, challenge, context} = init_documents(ctx)
    assert {:ok, pending} = ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)
    assert pending["state"] == "pending" and pending["applied_revision"] == nil
    assert pending["remaining_ms"] in 1..30_000
    assert {:ok, retry} = ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)
    assert Map.delete(retry, "remaining_ms") == Map.delete(pending, "remaining_ms")
    assert retry["remaining_ms"] <= pending["remaining_ms"]
    application = %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]}
    assert {:ok, applied} = ArchiveAuthorities.apply(:init, @installation, application, ctx.opts)
    assert applied["applied_revision"] == "1"
    assert applied["recording_readiness"] == "unavailable"
    assert applied["archive_readiness"] == "unavailable"
    assert {:ok, repeated} = ArchiveAuthorities.apply(:init, @installation, application, ctx.opts)
    assert repeated["expires_at_ms"] == applied["expires_at_ms"]

    assert {:ok, stored} =
             fn -> ArchiveAuthorities.status(:init, @installation, ctx.binding.id, ctx.opts) end
             |> Task.async()
             |> Task.await()

    assert Map.delete(stored, "remaining_ms") == Map.delete(applied, "remaining_ms")

    assert {:error, :init_authority_revision_conflict} =
             ArchiveAuthorities.challenge(
               :init,
               principal,
               Map.put(challenge, "storage_boot_id", Ecto.UUID.generate()),
               ctx.opts
             )

    assert {:error, :init_authority_origin_mismatch} =
             ArchiveAuthorities.status(
               :init,
               %{@installation | deployment_ref: Ecto.UUID.generate()},
               ctx.binding.id,
               ctx.opts
             )

    next_principal = %{principal | generation: 2}
    next_desired = Map.put(desired, "revision", "2")
    assert {:ok, parsed} = ArchiveAuthorityConfig.parse(:init, next_principal, next_desired)

    next_challenge =
      Map.merge(challenge, %{
        "revision" => "2",
        "desired_sha256" => parsed.desired_sha256,
        "storage_boot_id" => Ecto.UUID.generate(),
        "nonce" => digest("invented-next-challenge")
      })

    assert {:ok, %{"state" => "pending", "applied_revision" => nil}} =
             ArchiveAuthorities.challenge(:init, next_principal, next_challenge, ctx.opts)

    assert {:error, :init_authority_generation_stale} =
             ArchiveAuthorities.status(:init, @installation, ctx.binding.id, ctx.opts)

    assert {:error, :init_authority_generation_stale} =
             ArchiveAuthorities.apply(:init, @installation, application, ctx.opts)

    assert {:ok, revoked} =
             ArchiveAuthorities.revoke(:init, next_principal, revoke_document(ctx, "3"), ctx.opts)

    assert revoked["state"] == "revoked" and revoked["applied_revision"] == nil

    assert {:ok, ^revoked} =
             ArchiveAuthorities.revoke(:init, next_principal, revoke_document(ctx, "3"), ctx.opts)

    assert {:error, :init_authority_revision_stale} =
             ArchiveAuthorities.challenge(:init, next_principal, next_challenge, ctx.opts)

    assert {:ok, retained} = Ash.get(ArchiveInitAuthority, ctx.binding.id, ctx.opts)
    assert retained.desired_document == nil and retained.nonce == nil and retained.revision == 3
    assert context.desired_sha256 == applied["desired_sha256"]

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [
               Ecto.UUID.dump!(ctx.binding.id)
             ])
  end

  test "init authority rejects invalid actors, exact schemas and ambient transactions before writes",
       ctx do
    {principal, desired, challenge, _} = init_documents(ctx)
    application = %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]}

    for opts <- [[], [actor: %{role: :viewer, id: "invented-viewer"}], [actor: %{role: :system}]] do
      assert {:error, :invalid_init_principal} =
               ArchiveAuthorities.challenge(:init, principal, challenge, opts)

      assert {:error, :invalid_init_principal} =
               ArchiveAuthorities.apply(:init, @installation, application, opts)
    end

    for invalid <- [
          Map.put(challenge, "revision", "01"),
          Map.put(challenge, "schema_version", 1.0),
          Map.put(challenge, "extra", true),
          Map.put(challenge, "nonce", "invalid")
        ] do
      assert {:error, :invalid_init_challenge} =
               ArchiveAuthorities.challenge(:init, principal, invalid, ctx.opts)
    end

    assert {:error, :invalid_init_application} =
             ArchiveAuthorities.apply(
               :init,
               @installation,
               Map.put(application, "ready", true),
               ctx.opts
             )

    assert {:error, :invalid_init_revocation} =
             ArchiveAuthorities.revoke(
               :init,
               @installation,
               Map.put(revoke_document(ctx, "1"), "revision", 1),
               ctx.opts
             )

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveAuthorities.apply(:init, @installation, application, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveAuthorities.revoke(
                          :init,
                          @installation,
                          revoke_document(ctx, "1"),
                          ctx.opts
                        )

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.authorize(
                          :init,
                          ctx.lease,
                          Ecto.UUID.generate(),
                          principal,
                          %{},
                          ctx.opts
                        )

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.observe_verification(
                          :init,
                          ctx.lease,
                          Ecto.UUID.generate(),
                          principal,
                          %{},
                          %{},
                          ctx.opts
                        )

               :checked
             end)

    assert {:ok, %{"state" => "not_configured"}} =
             ArchiveAuthorities.status(:init, @installation, ctx.binding.id, ctx.opts)
  end

  test "init application cannot promote failed, stale or retargeted qualification reports", ctx do
    {principal, desired, _, _} = init_documents(ctx)

    variations = [
      {put_in(desired, ["qualification_report", "checks", "anonymous_access_denied"], "failed"),
       :init_authority_report_unqualified},
      {desired
       |> put_in(["qualification_report", "issued_at_ms"], 1)
       |> put_in(["qualification_report", "expires_at_ms"], 2), :init_authority_expired},
      {put_in(
         desired,
         ["qualification_report", "destination", "bucket"],
         "invented-other-recordings"
       ), :init_authority_context_mismatch}
    ]

    for {{changed, reason}, revision} <- Enum.with_index(variations, 1) do
      desired = Map.put(changed, "revision", Integer.to_string(revision))
      {challenge, _} = challenge_for(principal, desired)
      assert {:ok, _} = ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)

      assert {:error, ^reason} =
               ArchiveAuthorities.apply(
                 :init,
                 @installation,
                 %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]},
                 ctx.opts
               )

      assert {:ok, %{"state" => "pending", "applied_revision" => nil}} =
               ArchiveAuthorities.status(:init, @installation, ctx.binding.id, ctx.opts)
    end

    newer_origin = %{@installation | generation: 2}
    crossed_desired = Map.put(desired, "revision", "4")
    {crossed_challenge, _} = challenge_for(principal, crossed_desired)

    assert {:ok, newer_identity} =
             ArchiveAuthorityConfig.parse(:init, newer_origin, crossed_desired)

    crossed_challenge =
      Map.put(crossed_challenge, "desired_sha256", newer_identity.desired_sha256)

    assert {:ok, _} = ArchiveAuthorities.challenge(:init, principal, crossed_challenge, ctx.opts)

    assert {:error, :init_authority_context_mismatch} =
             ArchiveAuthorities.apply(
               :init,
               newer_origin,
               %{
                 "schema_version" => 1,
                 "desired" => crossed_desired,
                 "nonce" => crossed_challenge["nonce"]
               },
               ctx.opts
             )

    assert {:ok, %{"state" => "pending", "applied_revision" => nil}} =
             ArchiveAuthorities.status(:init, @installation, ctx.binding.id, ctx.opts)

    assert {:ok, %{capability_state: :unqualified}} =
             Ash.get(ArchiveBinding, ctx.binding.id, ctx.opts)
  end

  test "one init grant commits once and late verification preserves the original frozen media",
       ctx do
    bind(ctx)
    {principal, context} = install_init(ctx)

    assert {:ok, dispatch} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    results =
      race(fn _ ->
        ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)
      end)

    assert [{:ok, grant}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :init_dispatch_already_marked})) == 7
    assert grant["remaining_ms"] in 1..5000
    assert grant["byte_length"] == 1 and grant["object_sha256"] == digest("i")
    assert grant["local_storage_id"] == ctx.block.storage_id
    assert grant["object_key"] == "recordings/v1/#{ctx.block.block_key}/init.mp4"
    assert [marked] = dispatches(ctx)

    assert marked.init_authority_revision == 1 and
             marked.init_authority_sha256 == context.desired_sha256

    assert marked.init_storage_boot_id == context.storage_boot_id and
             marked.init_nonce_sha256 == digest(context.nonce)

    assert DateTime.diff(marked.init_deadline_at, marked.marked_at, :millisecond) in 1..5000

    assert {:ok, {:already_marked, _}} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    assert {:ok, _} =
             ArchiveAuthorities.revoke(:init, @installation, revoke_document(ctx, "2"), ctx.opts)

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, replacement} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    verification = %{
      "schema_version" => 1,
      "put_request_sha256" => digest("invented-signed-request"),
      "etag" => "\"invented-strong-etag\"",
      "version_id" => "invented-version",
      "byte_length" => 1,
      "object_sha256" => digest("i"),
      "encryption" => "AES256"
    }

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.observe_verification(
               :init,
               replacement,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert {:error, :init_verification_origin_mismatch} =
             ArchiveUploads.observe_verification(
               :init,
               ctx.lease,
               dispatch.id,
               %{principal | credential_generation: 2},
               context,
               verification,
               ctx.opts
             )

    for invalid <- [
          Map.put(verification, "object_sha256", digest("wrong")),
          Map.put(verification, "byte_length", 2),
          Map.put(verification, "etag", "W/\"weak\""),
          Map.put(verification, "encryption", "none"),
          Map.put(verification, "extra", true)
        ] do
      assert {:error, :invalid_init_verification} =
               ArchiveUploads.observe_verification(
                 :init,
                 ctx.lease,
                 dispatch.id,
                 principal,
                 context,
                 invalid,
                 ctx.opts
               )
    end

    assert {:ok, first} =
             ArchiveUploads.observe_verification(
               :init,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert {:ok, retry} =
             ArchiveUploads.observe_verification(
               :init,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert first.init_verified_at == retry.init_verified_at

    assert {:error, :init_verification_conflict} =
             ArchiveUploads.observe_verification(
               :init,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               Map.put(verification, "etag", "\"invented-other-etag\""),
               ctx.opts
             )

    assert {:ok, unknown} = ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)

    assert unknown.init_verification == verification and
             unknown.init_verified_at == first.init_verified_at

    assert unknown.init_verification_conflict_at != nil and unknown.marked_at == marked.marked_at

    assert {:ok, received} =
             ArchiveUploads.observe_response(ctx.lease, dispatch.id, %{"status" => 200}, ctx.opts)

    assert received.init_verification == verification and received.unknown_at != nil
    assert {:ok, block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert block.state == :uploading and block.descriptor == ctx.block.descriptor

    assert {:ok, %{capability_state: :unqualified}} =
             Ash.get(ArchiveBinding, ctx.binding.id, ctx.opts)
  end

  test "init grants reject changed boot, local storage, media operation and bookkeeping markers",
       ctx do
    bind(ctx)
    {principal, context} = install_init(ctx)

    assert {:ok, dispatch} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    assert {:error, :init_authority_context_mismatch} =
             ArchiveUploads.authorize(
               :init,
               ctx.lease,
               dispatch.id,
               principal,
               %{context | storage_boot_id: Ecto.UUID.generate()},
               ctx.opts
             )

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.authorize(
               :init,
               %{ctx.lease | upload_token: "invented-wrong"},
               dispatch.id,
               principal,
               context,
               ctx.opts
             )

    assert {:ok, media} = dispatch(ctx)

    assert {:error, :init_authority_context_mismatch} =
             ArchiveUploads.authorize(:init, ctx.lease, media.id, principal, context, ctx.opts)

    assert Enum.all?(dispatches(ctx), &is_nil(&1.marked_at))

    {principal, context} =
      install_init(ctx, "2", &Map.put(&1, "local_storage_id", Ecto.UUID.generate()))

    assert {:error, :init_authority_context_mismatch} =
             ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)

    {principal, context} = install_init(ctx, "3")

    assert {:ok, {:marked, original}} =
             ArchiveUploads.mark_dispatch(ctx.lease, dispatch.id, ctx.opts)

    assert {:error, :init_dispatch_already_marked} =
             ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)

    assert {:ok, retained} = Ash.get(ArchiveUploadDispatch, dispatch.id, ctx.opts)
    assert retained.marked_at == original.marked_at and retained.init_authority_revision == nil
  end

  for {restriction, denial} <- [stop: :recording_stopped, revoke: :init_authority_not_applied] do
    test "#{restriction} acknowledges only after an in-flight init grant commits", ctx do
      bind(ctx)
      {principal, context} = install_init(ctx)

      assert {:ok, dispatch} =
               ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

      holder = hold_block(ctx)
      assert_receive {:block_holder, holder_pid}, 5_000
      assert_receive :block_locked, 5_000

      admission =
        database_client(:init_grant, fn ->
          ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)
        end)

      assert_receive {:init_grant, admission_pid}, 5_000
      assert blocked_by?(admission_pid, holder_pid)
      restriction = unquote(restriction)

      restriction_task =
        database_client(:restriction, fn ->
          restrict_init(restriction, ctx)
        end)

      assert_receive {:restriction, restriction_pid}, 5_000
      assert blocked_by?(restriction_pid, admission_pid)
      reference = restriction_task.ref
      refute_receive {^reference, _}, 0
      send(holder.pid, :release_block)
      assert {:ok, :released} = Task.await(holder, 5_000)
      assert {:ok, %{"status" => "granted"}} = Task.await(admission, 5_000)
      assert {:ok, _} = Task.await(restriction_task, 5_000)

      expected = unquote(denial)

      assert {:error, ^expected} =
               ArchiveUploads.authorize(
                 :init,
                 ctx.lease,
                 dispatch.id,
                 principal,
                 context,
                 ctx.opts
               )

      assert [marked] = dispatches(ctx)
      assert marked.marked_at != nil and marked.init_authority_revision == 1
    end
  end

  test "authority expiry while waiting on the frozen block rolls back the first marker", ctx do
    bind(ctx)

    {principal, context} =
      install_init(ctx, "1", fn desired ->
        put_in(desired, ["qualification_report", "expires_at_ms"], database_ms() + 2_000)
      end)

    assert {:ok, dispatch} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    holder = hold_block(ctx)
    assert_receive {:block_holder, holder_pid}, 5_000
    assert_receive :block_locked, 5_000

    admission =
      database_client(:expiring_grant, fn ->
        ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)
      end)

    assert_receive {:expiring_grant, admission_pid}, 5_000
    assert blocked_by?(admission_pid, holder_pid)
    Process.sleep(2_100)
    send(holder.pid, :release_block)
    assert {:ok, :released} = Task.await(holder, 5_000)
    assert {:error, :upload_dispatch_expired} = Task.await(admission, 5_000)
    assert [retained] = dispatches(ctx)
    assert retained.marked_at == nil and retained.init_authority_revision == nil

    assert {:error, :init_authority_expired} =
             ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts)

    assert {:ok, block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert block.descriptor == ctx.block.descriptor and block.state == :uploading
  end

  test "a fractional millisecond cannot commit the only init grant", ctx do
    bind(ctx)
    {principal, context} = install_init(ctx)

    assert {:ok, dispatch} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    granted =
      Enum.reduce_while([500, 2_000, 8_000, 20_000, 80_000, 250_000], false, fn lead, _ ->
        assert %{num_rows: 1} = shift_dispatch_deadline(dispatch.id, lead)

        case ArchiveUploads.authorize(:init, ctx.lease, dispatch.id, principal, context, ctx.opts) do
          {:ok, grant} ->
            assert grant["remaining_ms"] in 1..5000
            assert [marked] = dispatches(ctx)
            assert DateTime.diff(marked.init_deadline_at, marked.marked_at, :millisecond) >= 1
            {:halt, true}

          {:error, :upload_dispatch_expired} ->
            assert [retained] = dispatches(ctx)
            assert retained.marked_at == nil and retained.init_authority_revision == nil
            {:cont, false}

          other ->
            flunk("short init grant returned #{inspect(other)}")
        end
      end)

    if granted == false do
      assert %{num_rows: 1} = restore_dispatch_deadline(dispatch.id)

      assert {:ok, grant} =
               ArchiveUploads.authorize(
                 :init,
                 ctx.lease,
                 dispatch.id,
                 principal,
                 context,
                 ctx.opts
               )

      assert grant["remaining_ms"] in 1..5000
      assert [marked] = dispatches(ctx)
      assert marked.marked_at != nil and marked.init_authority_revision == 1
    end
  end

  test "a fractional millisecond cannot apply an init authority", ctx do
    {principal, desired, challenge, _} = init_documents(ctx)
    assert {:ok, _} = ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)
    application = %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]}

    applied =
      Enum.reduce_while([500, 2_000, 8_000, 20_000, 80_000, 250_000], false, fn lead, _ ->
        assert %{num_rows: 1} = shift_authority_expiry(ctx.binding.id, lead)

        case ArchiveAuthorities.apply(:init, @installation, application, ctx.opts) do
          {:ok, %{"state" => "applied"}} ->
            assert {:ok, authority} = Ash.get(ArchiveInitAuthority, ctx.binding.id, ctx.opts)
            assert DateTime.diff(authority.expires_at, authority.applied_at, :millisecond) >= 1
            {:halt, true}

          {:error, :init_authority_expired} ->
            assert {:ok, %{state: :pending, applied_at: nil}} =
                     Ash.get(ArchiveInitAuthority, ctx.binding.id, ctx.opts)

            {:cont, false}

          other ->
            flunk("short init application returned #{inspect(other)}")
        end
      end)

    if applied == false do
      assert %{num_rows: 1} = restore_authority_expiry(ctx.binding.id)

      assert {:ok, %{"state" => "applied"}} =
               ArchiveAuthorities.apply(:init, @installation, application, ctx.opts)

      assert {:ok, authority} = Ash.get(ArchiveInitAuthority, ctx.binding.id, ctx.opts)
      assert DateTime.diff(authority.expires_at, authority.applied_at, :millisecond) >= 1
    end
  end

  test "media purpose is separately persisted and init authority cannot mark its dispatch", ctx do
    bind(ctx)
    {principal, init_context} = install_init(ctx)
    assert {:ok, dispatch} = dispatch(ctx)

    assert {:error, :init_authority_context_mismatch} =
             ArchiveUploads.authorize(
               :init,
               ctx.lease,
               dispatch.id,
               principal,
               init_context,
               ctx.opts
             )

    assert {:error, :media_authority_not_found} =
             ArchiveUploads.authorize(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               init_context,
               ctx.opts
             )

    assert {:ok, nil} =
             Ash.get(
               ArchiveMediaAuthority,
               ctx.binding.id,
               Keyword.put(ctx.opts, :not_found_error?, false)
             )

    {^principal, context} = install_media(ctx)
    assert {:ok, init} = Ash.get(ArchiveInitAuthority, ctx.binding.id, ctx.opts)
    assert init.desired_sha256 == init_context.desired_sha256
    assert {:ok, media} = Ash.get(ArchiveMediaAuthority, ctx.binding.id, ctx.opts)
    assert media.desired_sha256 == context.desired_sha256
    refute media.desired_sha256 == init.desired_sha256

    results =
      race(fn ->
        ArchiveUploads.authorize(:media, ctx.lease, dispatch.id, principal, context, ctx.opts)
      end)

    assert Enum.count(results, &match?({:ok, %{"status" => "granted"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :media_dispatch_already_marked}, &1)) == 7
    assert [retained] = dispatches(ctx)
    assert retained.media_authority_revision == 1
    assert retained.init_authority_revision == nil
    assert retained.media_verification == nil

    assert DateTime.diff(retained.media_deadline_at, retained.marked_at, :millisecond) in 1..30_000
  end

  test "media verification retains original grant evidence after revoke and replacement, with permanent conflicts",
       ctx do
    bind(ctx)
    {principal, context} = install_media(ctx)
    assert {:ok, dispatch} = dispatch(ctx)

    assert {:ok, grant} =
             ArchiveUploads.authorize(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               ctx.opts
             )

    assert {:ok, _} =
             ArchiveAuthorities.revoke(:media, @installation, revoke_document(ctx, "2"), ctx.opts)

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, replacement} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    verification = %{
      "schema_version" => 1,
      "put_request_sha256" => digest("synthetic signed media request"),
      "etag" => ~s("synthetic-media-etag"),
      "version_id" => "synthetic-media-version",
      "byte_length" => grant["byte_length"],
      "object_sha256" => grant["object_sha256"],
      "encryption" => "AES256"
    }

    assert {:error, :media_verification_origin_mismatch} =
             ArchiveUploads.observe_verification(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               %{context | nonce: digest("different")},
               verification,
               ctx.opts
             )

    assert {:ok, recorded} =
             ArchiveUploads.observe_verification(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert recorded.media_verification == verification
    assert recorded.media_verified_at != nil and recorded.init_verified_at == nil

    assert {:ok, exact} =
             ArchiveUploads.observe_verification(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert exact.media_verified_at == recorded.media_verified_at

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.authorize(
               :media,
               replacement,
               dispatch.id,
               principal,
               context,
               ctx.opts
             )

    assert {:error, :media_verification_conflict} =
             ArchiveUploads.observe_verification(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               %{verification | "etag" => ~s("different")},
               ctx.opts
             )

    assert {:error, :media_verification_conflict} =
             ArchiveUploads.observe_verification(
               :media,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    assert [conflicted] = dispatches(ctx)
    assert conflicted.media_verification == verification
    assert conflicted.media_verification_conflict_at
    assert {:ok, block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert block.descriptor == ctx.block.descriptor and block.state == :uploading
  end

  test "manifest identity consumes independent verified epochs without changing the frozen descriptor",
       ctx do
    bind(ctx)

    assert {:ok,
            %{
              status: :media_required,
              roles: %{init: :missing, media: :missing, manifest: :missing},
              result: nil
            }} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:error, :archive_dependencies_unverified} =
             ArchiveUploads.prepare_manifest(ctx.lease, ctx.opts)

    assert [] = intents(ctx)
    media = verified_object(ctx, :media)
    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, lease} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    next = %{ctx | lease: lease}
    init = verified_object(next, :init)
    assert init.dispatch.upload_epoch != media.dispatch.upload_epoch

    assert {:ok,
            %{
              status: :manifest_required,
              roles: %{init: :verified, media: :verified, manifest: :missing}
            }} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:ok, %{intent: intent, bytes: bytes}} =
             ArchiveUploads.prepare_manifest(lease, ctx.opts)

    assert intent.init_dispatch_id == init.dispatch.id
    assert intent.init_verification_sha256 == init.dispatch.init_verification_sha256
    assert intent.media_dispatch_id == media.dispatch.id
    assert intent.media_verification_sha256 == media.dispatch.media_verification_sha256
    assert intent.object_key == "recordings/v1/#{ctx.block.block_key}/manifest.json"
    assert intent.byte_length == byte_size(bytes) and intent.object_sha256 == digest(bytes)
    assert {:ok, decoded} = RecordingManifest.decode(bytes, ctx.block.descriptor["identity"])
    assert decoded["init"]["etag"] == ~s("synthetic-init-etag")
    assert decoded["media"]["etag"] == ~s("synthetic-media-etag")
    assert decoded["fragments"] == ctx.block.descriptor["fragments"]

    assert {:ok, %{intent: retry, bytes: ^bytes}} =
             ArchiveUploads.prepare_manifest(lease, ctx.opts)

    assert retry.id == intent.id and retry.inserted_at == intent.inserted_at
    assert {:ok, retained} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert retained.descriptor == ctx.block.descriptor
    assert retained.descriptor_sha256 == ctx.block.descriptor_sha256
    assert retained.archive_published_at == nil
  end

  test "an unmarked manifest remains tied to its original lease and unavailable after replacement",
       ctx do
    bind(ctx)
    verified_object(ctx, :media)
    verified_object(ctx, :init)
    assert {:ok, dispatch} = ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, ctx.opts)
    assert dispatch.marked_at == nil
    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, next} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:error, :archive_upload_dispatch_conflict} =
             ArchiveUploads.prepare_manifest_dispatch(next, 30_000, ctx.opts)

    assert {:error, :upload_lease_lost} = ArchiveUploads.publish_archive(ctx.lease, ctx.opts)

    assert {:error, :archive_publication_unverified} =
             ArchiveUploads.publish_archive(next, ctx.opts)

    assert {:ok, %{status: :reconciliation_required, roles: %{manifest: :prepared}, result: nil}} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:ok, retained} = Ash.get(ArchiveUploadDispatch, dispatch.id, ctx.opts)
    assert dispatch_identity(retained) == dispatch_identity(dispatch)
    assert retained.marked_at == nil and retained.manifest_authority_revision == nil
  end

  test "manifest grant rechecks its source evidence and preserves a prepared attempt on conflict",
       ctx do
    bind(ctx)
    verified_object(ctx, :media)
    init = verified_object(ctx, :init)
    assert {:ok, manifest} = ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, ctx.opts)
    {principal, context} = install_manifest(ctx)
    assert {:ok, authority} = Ash.get(ArchiveManifestAuthority, ctx.binding.id, ctx.opts)
    assert authority.desired_sha256 == context.desired_sha256

    assert {:error, :archive_upload_response_conflict} =
             ArchiveUploads.observe_response(
               ctx.lease,
               init.dispatch.id,
               %{"status" => 503},
               ctx.opts
             )

    assert {:error, :archive_upload_intent_conflict} =
             ArchiveUploads.authorize(
               :manifest,
               ctx.lease,
               manifest.id,
               principal,
               context,
               ctx.opts
             )

    assert {:ok, unchanged} = Ash.get(ArchiveUploadDispatch, manifest.id, ctx.opts)
    assert unchanged.marked_at == nil and unchanged.manifest_authority_revision == nil

    assert {:ok,
            %{
              status: :reconciliation_required,
              roles: %{init: :conflicted, manifest: :conflicted}
            }} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)
  end

  test "stop refuses a new init dispatch and leaves the retained media attempt unchanged", ctx do
    bind(ctx)
    media = verified_object(ctx, :media)
    assert {:ok, %{"stop_enforced" => true}} = RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert {:error, :recording_stopped} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :init, :put_object, 30_000, ctx.opts)

    assert [retained] = dispatches(ctx)
    assert dispatch_identity(retained) == dispatch_identity(media.dispatch)
    assert retained.deadline_at == media.dispatch.deadline_at
    assert Enum.filter(intents(ctx), &(&1.object_role == :init)) == []

    assert {:ok, retried} =
             ArchiveUploads.prepare_dispatch(ctx.lease, :media, :put_object, 30_000, ctx.opts)

    assert retried.id == media.dispatch.id
    assert retried.deadline_at == media.dispatch.deadline_at
    assert [unchanged] = dispatches(ctx)
    assert dispatch_identity(unchanged) == dispatch_identity(media.dispatch)
  end

  test "stop refuses a new manifest dispatch without changing verified init or media attempts", ctx do
    bind(ctx)
    media = verified_object(ctx, :media)
    init = verified_object(ctx, :init)
    assert {:ok, %{status: :manifest_required}} = ArchiveUploads.publication_status(ctx.block.id, ctx.opts)
    assert {:ok, %{"stop_enforced" => true}} = RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert {:error, :recording_stopped} =
             ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, ctx.opts)

    assert Enum.filter(intents(ctx), &(&1.object_role == :manifest)) == []
    retained = Map.new(dispatches(ctx), &{&1.id, dispatch_identity(&1)})
    assert retained[media.dispatch.id] == dispatch_identity(media.dispatch)
    assert retained[init.dispatch.id] == dispatch_identity(init.dispatch)
    assert {:ok, media_row} = Ash.get(ArchiveUploadDispatch, media.dispatch.id, ctx.opts)
    assert {:ok, init_row} = Ash.get(ArchiveUploadDispatch, init.dispatch.id, ctx.opts)
    assert media_row.deadline_at == media.dispatch.deadline_at
    assert init_row.deadline_at == init.dispatch.deadline_at
  end

  test "verified manifest publishes once under a new lease after stop and authority revocation",
       ctx do
    bind(ctx)
    verified_object(ctx, :media)
    verified_object(ctx, :init)
    manifest = verified_object(ctx, :manifest, 5000)
    Process.sleep(5_100)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT manifest_deadline_at < clock_timestamp() FROM platform.camera_archive_upload_dispatches WHERE id = $1",
               [Ecto.UUID.dump!(manifest.dispatch.id)]
             )

    assert {:ok, _} =
             ArchiveAuthorities.revoke(
               :manifest,
               @installation,
               revoke_document(ctx, "2"),
               ctx.opts
             )

    assert {:ok, %{"stop_enforced" => true}} =
             RecordingControl.stop(@installation, stop_document(), ctx.opts)

    assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)

    assert {:ok, lease} =
             RecordingBlocks.acquire_upload(ctx.block.id, Ecto.UUID.generate(), 30_000, ctx.opts)

    assert {:ok, %{status: :archive_verified, result: nil}} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:error, :upload_lease_lost} = ArchiveUploads.publish_archive(ctx.lease, ctx.opts)

    results = race(fn -> ArchiveUploads.publish_archive(lease, ctx.opts) end)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [{:ok, receipt}] = Enum.uniq(results)
    assert receipt["schema_version"] == 1 and receipt["status"] == "archive_published"
    assert receipt["block_id"] == ctx.block.id
    assert receipt["manifest_dispatch_id"] == manifest.dispatch.id

    assert receipt["manifest_verification_sha256"] ==
             manifest.dispatch.manifest_verification_sha256

    assert receipt["recording_readiness"] == "unavailable" and
             receipt["archive_readiness"] == "unavailable"

    assert map_size(receipt) == 8
    assert {:ok, published} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
    assert receipt["published_at"] == DateTime.to_iso8601(published.archive_published_at)
    assert published.state == :uploading and published.descriptor == ctx.block.descriptor
    assert {:ok, :released} = RecordingBlocks.release_upload(lease, ctx.opts)

    assert {:ok, %{status: :available, result: ^receipt}} =
             ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

    assert {:ok, retained} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)

    assert retained.state == :sealed and
             retained.archive_published_at == published.archive_published_at

    assert {:ok, dispatch} = Ash.get(ArchiveUploadDispatch, manifest.dispatch.id, ctx.opts)
    assert dispatch_identity(dispatch) == dispatch_identity(manifest.dispatch)
    assert dispatch.manifest_verified_at == manifest.dispatch.manifest_verified_at
  end

  for role <- [:init, :media, :manifest], conflict <- [:response, :verification] do
    test "late #{conflict} conflict for #{role} excludes availability while keeping publication history",
         ctx do
      bind(ctx)
      media = verified_object(ctx, :media)
      init = verified_object(ctx, :init)
      manifest = verified_object(ctx, :manifest)
      assert {:ok, receipt} = ArchiveUploads.publish_archive(ctx.lease, ctx.opts)
      assert {:ok, :released} = RecordingBlocks.release_upload(ctx.lease, ctx.opts)
      role = unquote(role)
      original = %{init: init, media: media, manifest: manifest}[role]
      conflict = unquote(conflict)

      case conflict do
        :response ->
          assert {:error, :archive_upload_response_conflict} =
                   ArchiveUploads.observe_response(
                     ctx.lease,
                     original.dispatch.id,
                     %{"status" => 503},
                     ctx.opts
                   )

        :verification ->
          reason =
            %{
              init: :init_verification_conflict,
              media: :media_verification_conflict,
              manifest: :manifest_verification_conflict
            }[role]

          assert {:error, ^reason} =
                   ArchiveUploads.observe_verification(
                     role,
                     ctx.lease,
                     original.dispatch.id,
                     original.principal,
                     original.context,
                     %{original.verification | "etag" => ~s("synthetic-conflicting-etag")},
                     ctx.opts
                   )
      end

      assert {:ok, status} = ArchiveUploads.publication_status(ctx.block.id, ctx.opts)
      assert status.status == :reconciliation_required
      assert status.roles[role] == :conflicted
      assert status.result == receipt

      assert {:ok, fresh} =
               RecordingBlocks.acquire_upload(
                 ctx.block.id,
                 Ecto.UUID.generate(),
                 30_000,
                 ctx.opts
               )

      assert {:error, :archive_publication_unverified} =
               ArchiveUploads.publish_archive(fresh, ctx.opts)

      assert {:ok, retained} = Ash.get(ArchiveUploadDispatch, original.dispatch.id, ctx.opts)

      field =
        %{init: :init_verification, media: :media_verification, manifest: :manifest_verification}[
          role
        ]

      assert Map.fetch!(retained, field) == original.verification
      assert {:ok, block} = Ash.get(RecordingBlock, ctx.block.id, ctx.opts)
      assert DateTime.to_iso8601(block.archive_published_at) == receipt["published_at"]
      assert block.archive_manifest_dispatch_id == manifest.dispatch.id
    end
  end

  test "publication owners reject ambient transactions and invalid actors without creating evidence",
       ctx do
    bind(ctx)

    for opts <- [[], [actor: %{role: :viewer, id: "synthetic-viewer"}]] do
      assert {:error, :invalid_dispatcher} = ArchiveUploads.publication_status(ctx.block.id, opts)
      assert {:error, :invalid_dispatcher} = ArchiveUploads.prepare_manifest(ctx.lease, opts)

      assert {:error, :invalid_dispatcher} =
               ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, opts)

      assert {:error, :invalid_dispatcher} = ArchiveUploads.publish_archive(ctx.lease, opts)
    end

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :ambient_transaction} =
                        ArchiveUploads.publication_status(ctx.block.id, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.prepare_manifest(ctx.lease, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, ctx.opts)

               assert {:error, :ambient_transaction} =
                        ArchiveUploads.publish_archive(ctx.lease, ctx.opts)

               :checked
             end)

    assert [] = intents(ctx)
    assert [] = dispatches(ctx)
  end

  defp verified_object(ctx, role, manifest_budget \\ 30_000) do
    {principal, context} =
      case role do
        :init -> install_init(ctx)
        :media -> install_media(ctx)
        :manifest -> install_manifest(ctx, manifest_budget)
      end

    bytes =
      case role do
        :init ->
          "i"

        :media ->
          "abc"

        :manifest ->
          assert {:ok, %{bytes: bytes}} = ArchiveUploads.prepare_manifest(ctx.lease, ctx.opts)
          bytes
      end

    {:ok, dispatch} =
      case role do
        :manifest -> ArchiveUploads.prepare_manifest_dispatch(ctx.lease, 30_000, ctx.opts)
        _ -> ArchiveUploads.prepare_dispatch(ctx.lease, role, :put_object, 30_000, ctx.opts)
      end

    assert {:ok, grant} =
             ArchiveUploads.authorize(role, ctx.lease, dispatch.id, principal, context, ctx.opts)

    assert grant["object_sha256"] == digest(bytes) and grant["byte_length"] == byte_size(bytes)

    verification = %{
      "schema_version" => 1,
      "put_request_sha256" => digest("synthetic signed #{role} request"),
      "etag" => ~s("synthetic-#{role}-etag"),
      "version_id" => "synthetic-#{role}-version",
      "byte_length" => byte_size(bytes),
      "object_sha256" => digest(bytes),
      "encryption" => "AES256"
    }

    assert {:ok, _} = ArchiveUploads.observe_unknown(ctx.lease, dispatch.id, ctx.opts)

    assert {:ok, _} =
             ArchiveUploads.observe_response(
               ctx.lease,
               dispatch.id,
               %{
                 "status" => 200,
                 "etag" => verification["etag"],
                 "version_id" => verification["version_id"]
               },
               ctx.opts
             )

    assert {:ok, verified} =
             ArchiveUploads.observe_verification(
               role,
               ctx.lease,
               dispatch.id,
               principal,
               context,
               verification,
               ctx.opts
             )

    %{dispatch: verified, principal: principal, context: context, verification: verification}
  end

  defp install_manifest(ctx, max_operation_ms \\ 30_000) do
    {principal, desired, challenge, context} =
      init_documents(ctx, "1", fn desired ->
        desired
        |> Map.put("operation", "manifest_put_verified_v1")
        |> Map.put("limits", %{
          "max_manifest_bytes" => 2_097_152,
          "max_operation_ms" => max_operation_ms,
          "max_in_flight" => 1
        })
      end)

    assert {:ok, _} = ArchiveAuthorities.challenge(:manifest, principal, challenge, ctx.opts)

    assert {:ok, %{"state" => "applied"}} =
             ArchiveAuthorities.apply(
               :manifest,
               @installation,
               %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]},
               ctx.opts
             )

    {principal, context}
  end

  defp install_media(ctx) do
    {principal, desired, challenge, context} =
      init_documents(ctx, "1", fn desired ->
        desired
        |> Map.put("operation", "media_put_verified_v1")
        |> Map.put("limits", %{
          "max_media_bytes" => 16_777_216,
          "max_operation_ms" => 30_000,
          "max_in_flight" => 1
        })
      end)

    assert {:ok, _} = ArchiveAuthorities.challenge(:media, principal, challenge, ctx.opts)

    assert {:ok, %{"state" => "applied"}} =
             ArchiveAuthorities.apply(
               :media,
               @installation,
               %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]},
               ctx.opts
             )

    {principal, context}
  end

  defp restrict_init(:stop, ctx),
    do: RecordingControl.stop(@installation, stop_document(), ctx.opts)

  defp restrict_init(:revoke, ctx),
    do: ArchiveAuthorities.revoke(:init, @installation, revoke_document(ctx, "2"), ctx.opts)

  defp shift_dispatch_deadline(id, lead_us) do
    Repo.query!(
      "UPDATE platform.camera_archive_upload_dispatches " <>
        "SET deadline_at = clock_timestamp() + ($2 * interval '1 microsecond') WHERE id = $1",
      [Ecto.UUID.dump!(id), lead_us]
    )
  end

  defp restore_dispatch_deadline(id) do
    Repo.query!(
      "UPDATE platform.camera_archive_upload_dispatches " <>
        "SET deadline_at = prepared_at + interval '20 seconds' WHERE id = $1",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp shift_authority_expiry(id, lead_us) do
    Repo.query!(
      "UPDATE platform.camera_archive_init_authorities " <>
        "SET expires_at = clock_timestamp() + ($2 * interval '1 microsecond') " <>
        "WHERE archive_binding_id = $1 AND state = 'pending'",
      [Ecto.UUID.dump!(id), lead_us]
    )
  end

  defp restore_authority_expiry(id) do
    Repo.query!(
      "UPDATE platform.camera_archive_init_authorities " <>
        "SET expires_at = issued_at + interval '20 seconds' " <>
        "WHERE archive_binding_id = $1 AND state = 'pending'",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp database_ms do
    %{rows: [[now]]} =
      Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint")

    now
  end

  defp init_documents(ctx, revision \\ "1", transform \\ &Function.identity/1) do
    principal =
      Map.merge(@installation, %{
        storage_service_id: "storage-worker-example",
        credential_reference: "storage-key-example",
        credential_generation: 1
      })

    now = database_ms()

    checks =
      ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery)

    desired = %{
      "schema_version" => 1,
      "revision" => revision,
      "binding_id" => ctx.binding.id,
      "local_storage_id" => ctx.block.storage_id,
      "operation" => "init_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{
        "max_init_bytes" => 1_048_576,
        "max_operation_ms" => 5000,
        "max_in_flight" => 1
      },
      "qualification_report" => %{
        "schema_version" => 1,
        "binding_id" => ctx.binding.id,
        "destination" => Fixtures.archive_destination(ctx.binding.provisioning_ref),
        "provider_resource_id" => "region-example/bucket-example",
        "endpoint_type" => "endpoint-class-example",
        "credential" => %{
          "reference" => principal.credential_reference,
          "generation" => 1,
          "storage_service_id" => principal.storage_service_id
        },
        "policy_revision" => "policy-example",
        "operation_mode" => "mediated_immutable_archive_v1",
        "issued_at_ms" => now - 1_000,
        "expires_at_ms" => now + 60_000,
        "result_ref" => "report-example",
        "checks" => Map.new(checks, &{&1, "passed"})
      }
    }

    desired = transform.(desired)
    {challenge, context} = challenge_for(principal, desired)
    {principal, desired, challenge, context}
  end

  defp challenge_for(principal, desired) do
    assert {:ok, kind} = ArchiveAuthorityConfig.kind(desired)
    assert {:ok, parsed} = ArchiveAuthorityConfig.parse(kind, principal, desired)
    boot = Ecto.UUID.generate()
    nonce = digest(Ecto.UUID.generate())

    {%{
       "schema_version" => 1,
       "revision" => desired["revision"],
       "binding_id" => desired["binding_id"],
       "desired_sha256" => parsed.desired_sha256,
       "storage_boot_id" => boot,
       "nonce" => nonce
     },
     %{
       desired_sha256: parsed.desired_sha256,
       storage_boot_id: boot,
       nonce: digest("grant:" <> nonce)
     }}
  end

  defp install_init(ctx, revision \\ "1", transform \\ &Function.identity/1) do
    {principal, desired, challenge, context} = init_documents(ctx, revision, transform)
    assert {:ok, _} = ArchiveAuthorities.challenge(:init, principal, challenge, ctx.opts)

    assert {:ok, %{"state" => "applied"}} =
             ArchiveAuthorities.apply(
               :init,
               @installation,
               %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]},
               ctx.opts
             )

    {principal, context}
  end

  defp revoke_document(ctx, revision),
    do: %{"schema_version" => 1, "binding_id" => ctx.binding.id, "revision" => revision}

  defp hold_block(ctx) do
    parent = self()

    database_client(:block_holder, fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM platform.camera_recording_blocks WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(ctx.block.id)
        ])

        send(parent, :block_locked)

        receive do
          :release_block -> :released
        after
          15_000 -> flunk("test block lock was not released")
        end
      end)
    end)
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
