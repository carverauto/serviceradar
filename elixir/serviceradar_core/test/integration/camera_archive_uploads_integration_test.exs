defmodule ServiceRadar.Camera.ArchiveUploadsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Camera.ArchiveBinding
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

    assert [retained] = intents(ctx)
    assert persisted_identity(retained) == persisted_identity(conflicting)
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
