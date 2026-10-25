defmodule ServiceRadar.Camera.RecordingWorkerIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingControl
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRecording.Worker
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    previous = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    previous_storage = Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

    Application.put_env(
      :serviceradar_core_elx,
      :camera_recording_storage_id,
      Ecto.UUID.generate()
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, previous)
      Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, previous_storage)
    end)

    start_supervised!(RecordingSupervisor)
    start_supervised!(ViewerRegistry)
    start_supervised!(PipelineManager)
    actor = SystemActor.system(:camera_recording_test)
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{device_uid: "sr:synthetic-recorder-#{key}", vendor: "acme", vendor_camera_id: key},
        actor: actor
      )

    {:ok, profile} =
      StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"},
        actor: actor
      )

    {:ok, relay} =
      RelaySession.create_session(
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          agent_id: "agent-example",
          gateway_id: "gateway-example"
        },
        actor: actor
      )

    ingest_id = Ecto.UUID.generate()

    {:ok, relay} =
      RelaySession.activate(
        relay,
        %{
          media_ingest_id: ingest_id,
          lease_expires_at: DateTime.shift(DateTime.utc_now(), minute: 1)
        },
        actor: actor
      )

    {:ok, %{pipeline_pid: pipeline}} =
      PipelineManager.open_session(%{relay_session_id: relay.id, media_ingest_id: ingest_id})

    on_exit(fn -> Membrane.Pipeline.terminate(pipeline, force?: true) end)
    root = Path.join(ctx.tmp_dir, "spool")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    {:ok, storage} =
      Storage.initialize(
        root,
        Application.fetch_env!(:serviceradar_core_elx, :camera_recording_storage_id)
      )

    media = SyntheticCameraMedia.generate(ctx.tmp_dir, "source")
    media = %{media | units: Enum.map(media.units, &Map.put(&1, :media_ingest_id, ingest_id))}

    %{
      source: source,
      profile: profile,
      relay: relay,
      pipeline: pipeline,
      actor: actor,
      root: root,
      storage: storage,
      media: media
    }
  end

  test "recorder retains ingest after viewer release and seals real media under its own lease",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {before_attach, after_attach} = Enum.split(ctx.media.units, 15)
    for unit <- before_attach, do: send(ctx.pipeline, {:media_chunk, unit})
    assert false == Membrane.Pipeline.call(ctx.pipeline, {:webrtc_viewer_alive?, "no-viewer"})
    {worker, ref} = start_worker(ctx, owner)
    assert :ok = IngestOwnership.release_consumer(owner, viewer.id, actor: ctx.actor)
    assert {:error, :consumers_active} = IngestOwnership.begin_idle_close(owner, actor: ctx.actor)
    assert [%{kind: :recorder}] = consumers(owner, ctx.actor)

    for unit <- after_attach do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_progress(worker, unit.sequence)
    end

    # Retain an independent consumer while teardown asks the public manager to
    # close idle ingest. This also keeps the test away from agent command dispatch.
    {:ok, analysis} =
      IngestOwnership.acquire_consumer(owner, :analysis, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    send(ctx.pipeline, :end_of_stream)

    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :completed, snapshot: snapshot}}},
                   5_000

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert [%{id: id}] = consumers(owner, ctx.actor)
    assert id == analysis.id
    assert snapshot.sealed?

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
      |> Ash.read!(actor: ctx.actor)

    assert block.state == :sealed
    assert block.descriptor["identity"] == snapshot.identity
    assert block.descriptor["init"] == snapshot.init
    assert block.descriptor["media"]["sha256"] == snapshot.sha256
    assert block.descriptor["format"]["codec"] =~ "avc1.42"

    assert {:ok, upload} =
             RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000,
               actor: ctx.actor
             )

    assert upload.storage_id ==
             Application.fetch_env!(:serviceradar_core_elx, :camera_recording_storage_id)

    assert {:ok, :released} = RecordingBlocks.release_upload(upload, actor: ctx.actor)

    assert %{next_block_sequence: 1, recorder_epoch: epoch, state: :released} =
             recorder_claim(ctx)

    assert snapshot.identity["recorder_epoch"] == epoch
    assert snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert List.last(snapshot.entries)["tail_duration_source"] == "previous_sample"
    assert {:ok, recovered} = Spool.recover(ctx.storage, snapshot.directory, snapshot.identity)
    assert hd(snapshot.entries)["start_ns"] == 3_000_000_000
    assert_packet_count(Spool.snapshot(recovered), ctx.tmp_dir, 45)
  end

  test "finite local capacity seals committed fragments and leaves live delivery running", ctx do
    owner = owner(ctx, 30_000)

    {:ok, _analysis} =
      IngestOwnership.acquire_consumer(owner, :analysis, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {worker, ref} = start_worker(ctx, owner, spool_limits: %{max_fragments: 1})

    stopped =
      Enum.reduce_while(ctx.media.units, nil, fn unit, _acc ->
        send(ctx.pipeline, {:media_chunk, unit})

        case await_progress(worker, unit.sequence) do
          :ok -> {:cont, nil}
          {:stopped, result} -> {:halt, result}
        end
      end)

    assert %{reason: :block_full, seal_error: nil, snapshot: snapshot} = stopped
    assert snapshot.sealed?
    assert length(snapshot.entries) == 1
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert_live_delivery(ctx, List.last(ctx.media.units))

    # A fresh recorder on the same still-running ingest must allocate a new
    # generation, preserving the previous immutable directory on this storage.
    {replacement, replacement_ref} = start_worker(ctx, owner)

    for unit <- Enum.take(ctx.media.units, 45) do
      unit = %{
        unit
        | pts: unit.pts + 450_000,
          dts: unit.dts + 450_000,
          sequence: unit.sequence + 75
      }

      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_progress(replacement, unit.sequence)
    end

    send(ctx.pipeline, :end_of_stream)

    assert_receive {:camera_recording, ^replacement,
                    {:stopped, %{reason: :completed, snapshot: next}}},
                   5_000

    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement, :normal}, 5_000
    assert next.identity["recorder_epoch"] == snapshot.identity["recorder_epoch"] + 1
    assert next.directory != snapshot.directory
    assert next.identity["clock"]["clock_epoch"] != snapshot.identity["clock"]["clock_epoch"]
    assert %{next_block_sequence: 1} = recorder_claim(ctx)
    assert {:ok, _old} = Spool.recover(ctx.storage, snapshot.directory, snapshot.identity)
    assert {:ok, _new} = Spool.recover(ctx.storage, next.directory, next.identity)
  end

  test "administrative stop drains and seals the recorder without renewing or interrupting its viewer",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {worker, ref} = start_worker(ctx, owner)

    for unit <- Enum.take(ctx.media.units, 45) do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_progress(worker, unit.sequence)
    end

    assert {:ok, _control} =
             RecordingControl.stop(
               %{deployment_ref: Ecto.UUID.generate(), generation: 1},
               %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"},
               actor: ctx.actor
             )

    stopped_claim = recorder_claim(ctx)

    # Let the existing renewal timer discover the durable stop. A synthetic
    # renewal message would not prove that an idle camera stops recording.
    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :recording_stopped, snapshot: snapshot, seal_error: nil}}},
                   7_000

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert snapshot.sealed?
    assert [%{id: viewer_id, kind: :viewer}] = consumers(owner, ctx.actor)
    assert viewer_id == viewer.id
    released_claim = recorder_claim(ctx)
    assert released_claim.state == :released
    assert released_claim.lease_expires_at == stopped_claim.lease_expires_at
    assert_live_delivery(ctx, List.last(ctx.media.units))

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
      |> Ash.read!(actor: ctx.actor)

    assert block.state == :sealed
    assert block.descriptor["media"]["sha256"] == snapshot.sha256
    assert List.last(snapshot.entries)["tail_duration_source"] == "previous_sample"
    assert {:ok, recovered} = Spool.recover(ctx.storage, snapshot.directory, snapshot.identity)
    assert_packet_count(Spool.snapshot(recovered), ctx.tmp_dir, 45)

    assert {:ok, replacement} =
             RecordingSupervisor.start_recorder(
               owner: owner,
               media_ingest_id: ctx.relay.media_ingest_id,
               spool_root: ctx.root,
               notify: self()
             )

    replacement_ref = Process.monitor(replacement)

    assert_receive {:camera_recording, ^replacement,
                    {:stopped, %{reason: :recording_stopped, snapshot: nil}}},
                   5_000

    refute_receive {:camera_recording, ^replacement, :ready}
    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement, replacement_reason}, 5_000
    assert replacement_reason in [:normal, :noproc]
    assert recorder_claim(ctx).recorder_epoch == released_claim.recorder_epoch

    assert [block.id] ==
             RecordingBlock
             |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
             |> Ash.read!(actor: ctx.actor)
             |> Enum.map(& &1.id)
  end

  test "an expired real consumer lease admits no queued work or readable receipt", ctx do
    owner = owner(ctx, 5_000)
    {worker, ref} = start_worker(ctx, owner)
    :ok = :sys.suspend(worker)
    [first, second | _] = ctx.media.units
    send(ctx.pipeline, {:media_chunk, first})
    # Expire the real, capped lease while its actual worker cannot consume media.
    Process.sleep(5_100)
    assert_live_delivery(ctx, second)
    :ok = :sys.resume(worker)

    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :lease_expired, snapshot: nil}}},
                   5_000

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert File.ls!(ctx.root) == [".storage-id"]

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
      |> Ash.read!(actor: ctx.actor)

    assert block.state == :open_local

    assert {:error, :recording_block_unfrozen} =
             RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000,
               actor: ctx.actor
             )
  end

  test "missing or misbound storage refuses startup before recorder authority and leaves live delivery",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    marker = Path.join(ctx.root, ".storage-id")
    File.rm!(marker)

    for {reason, sequence} <- [{:storage_identity_missing, 0}, {:storage_identity_mismatch, 1}] do
      if reason == :storage_identity_mismatch do
        {:ok, _} = Storage.initialize(ctx.root, Ecto.UUID.generate())
      end

      assert {:error, ^reason} =
               RecordingSupervisor.start_recorder(
                 owner: owner,
                 media_ingest_id: ctx.relay.media_ingest_id,
                 spool_root: ctx.root,
                 notify: self()
               )

      assert recorder_claim(ctx) == nil

      assert [] =
               RecordingBlock
               |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
               |> Ash.read!(actor: ctx.actor)

      assert [%{id: viewer_id, kind: :viewer}] = consumers(owner, ctx.actor)
      assert viewer_id == viewer.id
      assert_live_delivery(ctx, Enum.at(ctx.media.units, sequence))
    end
  end

  test "a changed marker stops recording without a new receipt or freeze and preserves live delivery",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, _viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {worker, ref} = start_worker(ctx, owner)
    {first, remaining} = Enum.split(ctx.media.units, 45)

    for unit <- first do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_progress(worker, unit.sequence)
    end

    assert {:ok, %{snapshot: %{entries: [_ | _]} = snapshot}} = Worker.status(worker)

    before =
      Map.new(File.ls!(snapshot.directory), &{&1, File.read!(Path.join(snapshot.directory, &1))})

    File.write!(Path.join(ctx.root, ".storage-id"), "00000000-0000-4000-8000-000000000012\n")
    assert {:error, :storage_identity_mismatch} = Worker.status(worker)
    for unit <- remaining, do: send(ctx.pipeline, {:media_chunk, unit})

    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :storage_identity_mismatch, snapshot: nil}}},
                   5_000

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000

    assert Map.new(
             File.ls!(snapshot.directory),
             &{&1, File.read!(Path.join(snapshot.directory, &1))}
           ) == before

    assert %{state: :released, next_block_sequence: 1} = recorder_claim(ctx)
    assert [%{kind: :viewer}] = consumers(owner, ctx.actor)
    assert_live_delivery(ctx, List.last(ctx.media.units))

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
      |> Ash.read!(actor: ctx.actor)

    assert block.state == :open_local
    assert block.descriptor == nil

    assert {:error, :recording_block_unfrozen} =
             RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000,
               actor: ctx.actor
             )
  end

  defp owner(ctx, ttl) do
    {:ok, owner} =
      IngestOwnership.acquire(ctx.source.id, ctx.profile.id, Ecto.UUID.generate(), ttl,
        actor: ctx.actor
      )

    {:ok, owner} = IngestOwnership.bind_relay(owner, ctx.relay.id, actor: ctx.actor)
    owner
  end

  defp start_worker(ctx, owner, opts \\ []) do
    {:ok, worker} =
      RecordingSupervisor.start_recorder(
        [
          owner: owner,
          media_ingest_id: ctx.relay.media_ingest_id,
          spool_root: ctx.root,
          notify: self()
        ] ++ opts
      )

    ref = Process.monitor(worker)
    assert_receive {:camera_recording, ^worker, :ready}, 5_000
    {worker, ref}
  end

  defp consumers(owner, actor) do
    {:ok, consumers} =
      ConsumerLease
      |> Ash.Query.filter(ingest_owner_id == ^owner.id and owner_epoch == ^owner.epoch)
      |> Ash.read(actor: actor)

    consumers
  end

  defp recorder_claim(ctx) do
    RecorderClaim
    |> Ash.Query.filter(relay_session_id == ^ctx.relay.id)
    |> Ash.read_one!(actor: ctx.actor)
  end

  defp await_progress(worker, sequence, attempts \\ 100)
  defp await_progress(_worker, _sequence, 0), do: flunk("recorder did not make bounded progress")

  defp await_progress(worker, sequence, attempts) do
    receive do
      {:camera_recording, ^worker, {:stopped, result}} -> {:stopped, result}
    after
      0 ->
        case Worker.status(worker) do
          {:ok, %{last_sequence: ^sequence}} ->
            :ok

          _ ->
            Process.sleep(10)
            await_progress(worker, sequence, attempts - 1)
        end
    end
  catch
    :exit, _ ->
      assert_receive {:camera_recording, ^worker, {:stopped, result}}, 5_000
      {:stopped, result}
  end

  defp assert_live_delivery(ctx, unit) do
    viewer = "synthetic-observer"
    :ok = RelayPubSub.subscribe_viewer(ctx.relay.id, viewer)
    :ok = RelayPubSub.viewer_join(ctx.relay.id, viewer)
    :sys.get_state(ViewerRegistry)
    send(ctx.pipeline, {:media_chunk, unit})
    sequence = unit.sequence
    assert_receive {:camera_relay_viewer_chunk, %{sequence: ^sequence}}, 1_000
    assert Process.alive?(ctx.pipeline)
  end

  defp assert_packet_count(snapshot, directory, expected) do
    {:ok, init} = Spool.read_init(snapshot)

    payload =
      Enum.map(snapshot.entries, fn entry ->
        {:ok, bytes} = Spool.read_fragment(snapshot, entry["sequence"])
        bytes
      end)

    path = Path.join(directory, "recovered.mp4")
    File.write!(path, [init | payload])

    args = [
      "-v",
      "error",
      "-count_packets",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=nb_read_packets",
      "-of",
      "csv=p=0",
      path
    ]

    assert {output, 0} =
             System.cmd(SyntheticCameraMedia.tool("ffprobe"), args, stderr_to_stdout: true)

    assert String.trim(output) == Integer.to_string(expected)
  end
end
