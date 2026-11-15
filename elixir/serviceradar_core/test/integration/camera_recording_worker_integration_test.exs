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
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarCoreElx.CameraRecording.Capture
  alias ServiceRadarCoreElx.CameraRecording.NVRCapture
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRecording.Worker
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir
  @replaced_marker "00000000-0000-4000-8000-000000000099\n"

  setup ctx do
    Fixtures.recording_recovery_gate(ctx.tmp_dir)
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    previous = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    previous_storage = Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
    previous_root = Application.get_env(:serviceradar_core_elx, :camera_recording_spool_root)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

    Application.put_env(
      :serviceradar_core_elx,
      :camera_recording_storage_id,
      Ecto.UUID.generate()
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, previous)
      Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, previous_storage)
      Application.put_env(:serviceradar_core_elx, :camera_recording_spool_root, previous_root)
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
    Application.put_env(:serviceradar_core_elx, :camera_recording_spool_root, root)

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

  test "one-shot capture freezes only three complete fragments and releases its own consumer",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {task, worker, ref} = start_capture(ctx, owner)

    for unit <- Enum.take(ctx.media.units, 45) do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_capture_progress(worker, unit.sequence)
    end

    assert {:ok, %{snapshot: snapshot}} = Worker.status(worker)
    assert snapshot.high_water > 0

    repeated =
      Enum.map(ctx.media.units, fn unit ->
        %{unit | pts: unit.pts + 450_000, dts: unit.dts + 450_000, sequence: unit.sequence + 75}
      end)

    Enum.reduce_while(Enum.drop(ctx.media.units, 45) ++ repeated, nil, fn unit, _acc ->
      send(ctx.pipeline, {:media_chunk, unit})

      case await_capture_progress(worker, unit.sequence) do
        :ok -> {:cont, nil}
        :stopped -> {:halt, nil}
      end
    end)

    assert {:ok, %{block_id: block_id} = receipt} = Task.await(task, 5_000)
    assert Map.keys(receipt) == [:block_id]
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert [%{id: viewer_id, kind: :viewer}] = consumers(owner, ctx.actor)
    assert viewer_id == viewer.id
    assert recorder_claim(ctx).state == :released

    [block] = recording_blocks(ctx)
    assert block.id == block_id
    assert block.state == :sealed
    assert block.archive_published_at == nil
    assert block.descriptor["identity"]["clock"]["utc_mapping"] == "unknown"
    assert length(block.descriptor["fragments"]) == 3
    assert block.descriptor["init"]["length"] <= 1_048_576
    assert block.descriptor["media"]["length"] <= 16_777_216
    assert Enum.all?(block.descriptor["fragments"], &(&1["length"] <= 4_194_304))

    assert {:ok, recovered} = Spool.recover(ctx.storage, snapshot.directory, snapshot.identity)
    recovered = Spool.snapshot(recovered)
    assert recovered.sealed?

    assert Enum.map(recovered.entries, & &1["sha256"]) ==
             Enum.map(block.descriptor["fragments"], & &1["sha256"])

    assert recovered.sha256 == block.descriptor["media"]["sha256"]
    assert_packet_count(recovered, ctx.tmp_dir, 105)
    assert_live_delivery(ctx, List.last(repeated))
  end

  test "losing the one-shot caller stops recording while preserving local bytes and its viewer",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {task, worker, ref} = start_capture(ctx, owner)

    for unit <- Enum.take(ctx.media.units, 45) do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_capture_progress(worker, unit.sequence)
    end

    assert {:ok, %{snapshot: snapshot}} = Worker.status(worker)
    assert snapshot.high_water > 0

    files =
      Map.new(
        ~w(init.mp4 media.m4s journal),
        &{&1, File.read!(Path.join(snapshot.directory, &1))}
      )

    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert [%{id: viewer_id, kind: :viewer}] = consumers(owner, ctx.actor)
    assert viewer_id == viewer.id
    assert recorder_claim(ctx).state == :released

    assert [%{state: :open_local, descriptor: nil, archive_published_at: nil}] =
             recording_blocks(ctx)

    for {name, bytes} <- files do
      assert File.read!(Path.join(snapshot.directory, name)) == bytes
    end

    assert_live_delivery(ctx, List.last(ctx.media.units))
  end

  test "one-shot deadline includes a stalled start and survives loss of its caller", ctx do
    owner = owner(ctx, 90_000)
    tasks = start_supervised!(Task.Supervisor)
    workers = ServiceRadarCoreElx.CameraRecording.Workers
    :ok = :sys.suspend(workers)

    try do
      task = Task.Supervisor.async_nolink(tasks, fn -> Capture.once(ctx.relay.id) end)
      abandoned = Task.Supervisor.async_nolink(tasks, fn -> Capture.once(ctx.relay.id) end)
      coordinator = await_stalled_capture(abandoned, workers)
      coordinator_ref = Process.monitor(coordinator)
      Task.shutdown(abandoned, :brutal_kill)
      assert {:error, :capture_timeout} = Task.await(task, 35_000)
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :killed}, 5_000
    after
      :ok = :sys.resume(workers)
    end

    # The call is ordered behind the late start request. That request must not
    # create a recorder with a fresh budget after its coordinator has gone away.
    assert [] == DynamicSupervisor.which_children(workers)
    assert {:ok, current_owner} = IngestOwnership.for_relay(ctx.relay.id, actor: ctx.actor)
    assert current_owner.id == owner.id
    assert current_owner.epoch == owner.epoch
    assert [] == recording_blocks(ctx)
    assert [] == consumers(owner, ctx.actor)
    assert_live_delivery(ctx, List.last(ctx.media.units))
  end

  test "one-shot admission cannot bypass installed opt-in or durable stop", ctx do
    owner = owner(ctx, 30_000)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    assert {:error, :recording_disabled} = Capture.once(ctx.relay.id)
    assert [] == recording_blocks(ctx)
    assert [] == consumers(owner, ctx.actor)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

    assert {:ok, _control} =
             RecordingControl.stop(
               %{deployment_ref: Ecto.UUID.generate(), generation: 1},
               %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"},
               actor: ctx.actor
             )

    assert {:error, :recording_stopped} = Capture.once(ctx.relay.id)
    assert [] == recording_blocks(ctx)
    assert [] == consumers(owner, ctx.actor)
    assert_live_delivery(ctx, List.last(ctx.media.units))
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
    first = Enum.take(ctx.media.units, 45)

    for unit <- first do
      send(ctx.pipeline, {:media_chunk, unit})
      assert :ok = await_progress(worker, unit.sequence)
    end

    assert {:ok, %{snapshot: %{entries: [_ | _]} = snapshot}} = Worker.status(worker)

    before =
      Map.new(File.ls!(snapshot.directory), &{&1, File.read!(Path.join(snapshot.directory, &1))})

    File.write!(Path.join(ctx.root, ".storage-id"), "00000000-0000-4000-8000-000000000012\n")
    assert {:error, :storage_identity_mismatch} = Worker.status(worker)
    release_hook = capture_slow_recorder_release(1_100)
    # A burst of the remaining units can fill the finite inbox and stop as
    # queue_full before persistence reaches the storage guard. Renewal is the
    # scheduled production event that checks storage first.
    send(worker, :renew_lease)

    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :storage_identity_mismatch, snapshot: nil}}},
                   5_000

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    detach_freeze_hook(release_hook)
    assert_receive {:recorder_claim_released_by, ^worker}, 1_000

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

  test "marker replacement across freeze keeps the end-of-stream receipt and refuses current reads",
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

    # Rewrite the marker when the freeze update returns, before the worker
    # treats that committed row as its stopped receipt.
    handler = capture_freeze_marker_replacement(ctx.root)
    send(ctx.pipeline, :end_of_stream)

    assert_receive {:camera_recording, ^worker,
                    {:stopped, %{reason: :completed, snapshot: snapshot, seal_error: nil}}},
                   5_000

    detach_freeze_hook(handler)
    assert_historical_receipt(ctx, worker, ref, snapshot)
    assert [%{id: viewer_id, kind: :viewer}] = consumers(owner, ctx.actor)
    assert viewer_id == viewer.id
  end

  test "marker replacement across freeze keeps the finite-capacity receipt and refuses current reads",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, _viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    {worker, ref} = start_worker(ctx, owner, spool_limits: %{max_fragments: 1})
    handler = capture_freeze_marker_replacement(ctx.root)

    stopped =
      Enum.reduce_while(ctx.media.units, nil, fn unit, _acc ->
        send(ctx.pipeline, {:media_chunk, unit})

        case await_progress(worker, unit.sequence) do
          :ok -> {:cont, nil}
          {:stopped, result} -> {:halt, result}
        end
      end)

    detach_freeze_hook(handler)
    assert %{reason: :block_full, seal_error: nil, snapshot: snapshot} = stopped
    assert snapshot.sealed?
    assert length(snapshot.entries) == 1
    assert_historical_receipt(ctx, worker, ref, snapshot)
    assert [%{kind: :viewer}] = consumers(owner, ctx.actor)
    assert_live_delivery(ctx, List.last(ctx.media.units))
  end

  defp recording_blocks(ctx) do
    RecordingBlock
    |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
    |> Ash.read!(actor: ctx.actor)
  end

  defp start_capture(ctx, owner) do
    tasks = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(tasks, fn -> Capture.once(ctx.relay.id) end)
    deadline = System.monotonic_time(:millisecond) + 5_000

    worker =
      await_capture(
        fn ->
          case Registry.lookup(
                 ServiceRadarCoreElx.CameraRecording.Registry,
                 {owner.id, owner.epoch}
               ) do
            [{worker, _}] ->
              case Worker.status(worker) do
                {:ok, _} -> {:ready, worker}
                _ -> :waiting
              end

            [] ->
              :waiting
          end
        end,
        deadline
      )

    {task, worker, Process.monitor(worker)}
  end

  defp await_stalled_capture(task, workers) do
    await_capture(
      fn ->
        {:monitors, monitors} = Process.info(task.pid, :monitors)
        {:messages, messages} = Process.info(Process.whereis(workers), :messages)

        case Enum.find_value(messages, fn
               {:"$gen_call", {pid, _tag}, _request} ->
                 if {:process, pid} in monitors, do: pid

               _ ->
                 nil
             end) do
          nil -> :waiting
          coordinator -> {:ready, coordinator}
        end
      end,
      System.monotonic_time(:millisecond) + 5_000
    )
  end

  defp await_capture_progress(worker, sequence) do
    await_capture(
      fn ->
        case Worker.status(worker) do
          {:ok, %{last_sequence: ^sequence}} -> {:ready, :ok}
          _ -> :waiting
        end
      end,
      System.monotonic_time(:millisecond) + 5_000
    )
  catch
    :exit, {:noproc, _} -> :stopped
    :exit, {:normal, _} -> :stopped
  end

  defp await_capture(probe, deadline) do
    case probe.() do
      {:ready, result} ->
        result

      :waiting ->
        assert System.monotonic_time(:millisecond) < deadline,
               "one-shot recorder did not make bounded progress"

        receive do
        after
          10 -> await_capture(probe, deadline)
        end
    end
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

  defp capture_freeze_marker_replacement(root) do
    handler_id = {__MODULE__, make_ref()}
    parent = self()
    {:ok, once} = Agent.start_link(fn -> false end)

    on_exit(fn ->
      detach_freeze_hook(handler_id)
      if Process.alive?(once), do: Agent.stop(once)
    end)

    event = ServiceRadar.Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, _config ->
          if freeze_update?(metadata) and claim_once(once) do
            File.write!(Path.join(root, ".storage-id"), @replaced_marker)
            send(parent, {:marker_replaced_across_freeze, self()})
          end
        end,
        nil
      )

    handler_id
  end

  defp capture_slow_recorder_release(delay_ms) do
    handler_id = {__MODULE__, make_ref()}
    parent = self()
    {:ok, once} = Agent.start_link(fn -> false end)

    on_exit(fn ->
      detach_freeze_hook(handler_id)
      if Process.alive?(once), do: Agent.stop(once)
    end)

    event = ServiceRadar.Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, _config ->
          if recorder_claim_release_update?(metadata) and claim_once(once) do
            Process.sleep(delay_ms)
            send(parent, {:recorder_claim_released_by, self()})
          end
        end,
        nil
      )

    handler_id
  end

  defp detach_freeze_hook(handler_id) do
    _ = :telemetry.detach(handler_id)
    :ok
  end

  defp claim_once(agent) do
    Agent.get_and_update(agent, fn seen -> {not seen, true} end)
  end

  defp recorder_claim_release_update?(%{query: query} = metadata) do
    sql = query |> query_text() |> String.downcase()
    source = metadata[:source]

    claims? =
      source == "camera_recorder_claims" or String.contains?(sql, "camera_recorder_claims")

    params = List.wrap(metadata[:params])

    released? =
      Enum.any?(params, &(&1 in ["released", :released])) or String.contains?(sql, "'released'")

    successful_query?(metadata) and claims? and released? and update_statement?(sql)
  end

  defp recorder_claim_release_update?(_metadata), do: false

  defp freeze_update?(%{query: query} = metadata) do
    sql = query |> query_text() |> String.downcase()
    source = metadata[:source]

    blocks? =
      source == "camera_recording_blocks" or String.contains?(sql, "camera_recording_blocks")

    successful_query?(metadata) and blocks? and String.contains?(sql, "descriptor") and
      update_statement?(sql)
  end

  defp freeze_update?(_metadata), do: false

  defp update_statement?(sql) do
    String.match?(sql, ~r/(?:^|\s)update\s/) and
      not String.match?(sql, ~r/(?:^|\s)for\s+update\b/)
  end

  defp successful_query?(%{result: {:ok, _}}), do: true
  defp successful_query?(%{result: %{num_rows: rows}}) when is_integer(rows), do: true
  defp successful_query?(_metadata), do: false

  defp query_text(query) when is_binary(query), do: query
  defp query_text(query) when is_list(query), do: IO.iodata_to_binary(query)
  defp query_text(%{query: query}), do: query_text(query)
  defp query_text(_query), do: ""

  defp assert_historical_receipt(ctx, worker, ref, snapshot) do
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert_receive {:marker_replaced_across_freeze, ^worker}, 1_000
    assert snapshot.sealed?
    assert {:error, :storage_identity_mismatch} = Storage.verify(ctx.storage)
    assert {:error, :storage_identity_mismatch} = Spool.read_init(snapshot)

    assert {:error, :storage_identity_mismatch} =
             Spool.recover(ctx.storage, snapshot.directory, snapshot.identity)

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^ctx.source.id)
      |> Ash.read!(actor: ctx.actor)

    assert block.state == :sealed
    assert block.descriptor["identity"] == snapshot.identity
    assert block.descriptor["media"]["sha256"] == snapshot.sha256

    assert {:ok, upload} =
             RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000,
               actor: ctx.actor
             )

    assert upload.storage_id ==
             Application.fetch_env!(:serviceradar_core_elx, :camera_recording_storage_id)

    assert {:ok, :released} = RecordingBlocks.release_upload(upload, actor: ctx.actor)
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

  test "NVRCapture.once_source streams bounded relay media into serviceradar_nvr, retains decodable fMP4 across restart, and keeps catalog state open_local",
       ctx do
    nvr_ctx = Fixtures.context()
    nvr = setup_nvr_release(ctx.tmp_dir)
    daemon = start_nvr_daemon(nvr)
    parent = self()

    task =
      Task.async(fn ->
        NVRCapture.once_source(
          nvr_ctx.source.id,
          nvr_ctx.profile.id,
          "serviceradar-nvr-0",
          actor: nvr_ctx.actor,
          control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
          dispatch_open: fn _agent, payload, opts, _requester ->
            send(parent, {:nvr_relay_open_dispatched, payload.relay_session_id})
            {:ok, opts[:command_id]}
          end,
          config_file: nvr.client_config,
          token_file: nvr.token_file,
          bounds: %{max_frames: 60, max_bytes: 8_388_608, max_duration_ms: 6_000}
        )
      end)

    assert_receive {:nvr_relay_open_dispatched, relay_id}, 5_000
    assert {:ok, pending_relay} = RelaySession.get_by_id(relay_id, actor: nvr_ctx.actor)
    ingest_id = Ecto.UUID.generate()
    assert {:ok, active_relay} = Fixtures.activate(nvr_ctx, pending_relay, ingest_id)
    nvr_owner = Fixtures.owner(nvr_ctx)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(nvr_owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: nvr_ctx.actor
      )

    {:ok, %{pipeline_pid: pipeline}} =
      PipelineManager.open_session(%{
        relay_session_id: active_relay.id,
        media_ingest_id: ingest_id
      })

    on_exit(fn -> Membrane.Pipeline.terminate(pipeline, force?: true) end)

    _worker = await_nvr_worker_attached(nvr_owner)
    units = Enum.map(ctx.media.units, &Map.put(&1, :media_ingest_id, ingest_id))
    Enum.each(units, &send(pipeline, {:media_chunk, &1}))

    assert {:ok, receipt} = Task.await(task, 15_000)
    assert receipt.status == :sealed_local
    assert receipt.storage_id == nvr.storage_id
    assert receipt.member == "serviceradar-nvr-0"
    assert receipt.relay_session_id == active_relay.id
    assert receipt.recorder_epoch == 1
    assert receipt.frames_sent == 60
    assert receipt.bytes_sent > 0
    assert String.match?(receipt.block_key, ~r/\A[0-9a-f]{64}\z/)

    assert [%{id: viewer_id, kind: :viewer}] = consumers(nvr_owner, nvr_ctx.actor)
    assert viewer_id == viewer.id

    claim =
      RecorderClaim
      |> Ash.Query.filter(relay_session_id == ^active_relay.id)
      |> Ash.read_one!(actor: nvr_ctx.actor)

    assert claim.state == :released
    assert claim.storage_id == nvr.storage_id
    assert claim.recorder_epoch == 1
    assert claim.next_block_sequence == 1

    [block] =
      RecordingBlock
      |> Ash.Query.filter(camera_source_id == ^nvr_ctx.source.id)
      |> Ash.read!(actor: nvr_ctx.actor)

    assert block.id == receipt.recording_block_id
    assert block.block_key == receipt.block_key
    assert block.storage_id == nvr.storage_id
    assert block.state == :open_local
    assert block.descriptor == nil
    assert block.archive_published_at == nil

    assert {:error, :recording_block_unfrozen} =
             RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000,
               actor: nvr_ctx.actor
             )

    assert_live_delivery(%{relay: active_relay, pipeline: pipeline}, List.last(units))

    stop_nvr_daemon(daemon)
    restarted = start_nvr_daemon(nvr)
    stop_nvr_daemon(restarted)

    exported_mp4 = export_nvr_block(nvr, receipt.block_key)
    mp4_bytes = File.read!(exported_mp4)
    assert byte_size(mp4_bytes) in 1..16_777_216

    expected_raw = binary_part(decode_rawvideo(ctx.media.path), 0, 60 * div(64 * 64 * 3, 2))
    assert decode_rawvideo(exported_mp4) == expected_raw
  end

  test "NVRCapture mid-stream transport drop returns uncertain without retrying, failing over, or releasing the active recorder fence",
       ctx do
    owner = owner(ctx, 30_000)

    {:ok, viewer} =
      IngestOwnership.acquire_consumer(owner, :viewer, Ecto.UUID.generate(), 30_000,
        actor: ctx.actor
      )

    abs_tmp = Path.expand(ctx.tmp_dir)
    certs = write_nvr_mtls_certs(Path.join(abs_tmp, "uncertain-certs"))
    parent = self()
    nvr0_port = start_dropping_tls_peer(certs, parent)
    nvr1_port = start_forbidding_tls_peer(certs, parent)
    nvr0_storage_id = Ecto.UUID.generate()
    nvr1_storage_id = Ecto.UUID.generate()

    token_file = Path.join(abs_tmp, "uncertain-token")
    config_file = Path.join(abs_tmp, "uncertain-client.json")
    File.write!(token_file, "synthetic-nvr-uncertain-token-0123456789")

    File.write!(
      config_file,
      Jason.encode!(%{
        "version" => 1,
        "port" => nvr0_port,
        "ca_file" => certs.client_ca,
        "cert_file" => certs.client_cert,
        "key_file" => certs.client_key,
        "members" => %{
          "serviceradar-nvr-0" => %{"host" => "localhost", "storage_id" => nvr0_storage_id},
          "serviceradar-nvr-1" => %{
            "host" => "localhost",
            "port" => nvr1_port,
            "storage_id" => nvr1_storage_id
          }
        }
      })
    )

    task =
      Task.async(fn ->
        NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
          actor: ctx.actor,
          config_file: config_file,
          token_file: token_file,
          timeout_ms: 8_000,
          bounds: %{max_frames: 20, max_bytes: 8_388_608, max_duration_ms: 6_000}
        )
      end)

    worker = await_nvr_worker_attached(owner)
    worker_ref = Process.monitor(worker)
    Enum.each(Enum.take(ctx.media.units, 5), &send(ctx.pipeline, {:media_chunk, &1}))
    assert_receive {:nvr0_closed_mid_stream, 1}, 5_000

    # The client reads the socket passively, so it only observes the drop when it
    # next writes; keep feeding units until the worker exits.
    Enum.reduce_while(Enum.slice(ctx.media.units, 5, 15), :ok, fn unit, :ok ->
      if Process.alive?(worker) do
        send(ctx.pipeline, {:media_chunk, unit})
        Process.sleep(20)
        {:cont, :ok}
      else
        {:halt, :ok}
      end
    end)

    assert {:error, {:nvr_ingest_uncertain, details}} = Task.await(task, 10_000)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 5_000
    refute_receive {:nvr0_closed_mid_stream, _}, 200
    refute_receive {:unexpected_nvr1_failover, _}, 200

    assert details.storage_id == nvr0_storage_id
    assert details.member == "serviceradar-nvr-0"
    assert details.recorder_epoch == 1
    assert details.relay_session_id == ctx.relay.id

    claim = recorder_claim(ctx)
    assert claim.state == :active
    assert claim.storage_id == nvr0_storage_id
    assert claim.recorder_epoch == 1

    [block] = recording_blocks(ctx)
    assert block.id == details.recording_block_id
    assert block.block_key == details.block_key
    assert block.state == :open_local
    assert block.descriptor == nil

    assert [%{kind: :recorder}, %{id: viewer_id, kind: :viewer}] =
             Enum.sort_by(consumers(owner, ctx.actor), & &1.kind)

    assert viewer_id == viewer.id
    assert_live_delivery(ctx, List.last(ctx.media.units))
  end

  test "NVRCapture refuses a clean seal when the relay drain fails after a bound and keeps the recorder fence",
       ctx do
    owner = owner(ctx, 30_000)
    nvr = setup_nvr_release(ctx.tmp_dir)
    _daemon = start_nvr_daemon(nvr)

    task =
      Task.async(fn ->
        NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
          actor: ctx.actor,
          config_file: nvr.client_config,
          token_file: nvr.token_file,
          bounds: %{max_frames: 5, max_bytes: 8_388_608, max_duration_ms: 6_000}
        )
      end)

    worker = await_nvr_worker_attached(owner)
    :ok = :sys.suspend(worker)
    Enum.each(Enum.take(ctx.media.units, 5), &send(ctx.pipeline, {:media_chunk, &1}))
    _ = :sys.get_state(ctx.pipeline)
    :ok = :sys.suspend(ctx.pipeline)

    result =
      try do
        :ok = :sys.resume(worker)
        Task.await(task, 20_000)
      after
        :sys.resume(ctx.pipeline)
      end

    assert {:error, {:nvr_ingest_uncertain, details}} = result
    assert details.storage_id == nvr.storage_id
    assert details.recorder_epoch == 1

    claim = recorder_claim(ctx)
    assert claim.state == :active
    assert claim.storage_id == nvr.storage_id
    assert claim.recorder_epoch == 1

    [block] = recording_blocks(ctx)
    assert block.block_key == details.block_key
    assert block.state == :open_local
    assert block.descriptor == nil
  end

  test "NVRCapture administrative stop drains admitted units, seals them, and releases the recorder fence",
       ctx do
    owner = owner(ctx, 30_000)
    nvr = setup_nvr_release(ctx.tmp_dir)
    _daemon = start_nvr_daemon(nvr)

    task =
      Task.async(fn ->
        NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
          actor: ctx.actor,
          config_file: nvr.client_config,
          token_file: nvr.token_file,
          bounds: %{max_frames: 60, max_bytes: 8_388_608, max_duration_ms: 20_000}
        )
      end)

    worker = await_nvr_worker_attached(owner)

    Enum.each(Enum.take(ctx.media.units, 8), fn unit ->
      send(ctx.pipeline, {:media_chunk, unit})
      Process.sleep(50)
    end)

    _ = :sys.get_state(ctx.pipeline)

    assert {:ok, _control} =
             RecordingControl.stop(
               %{deployment_ref: Ecto.UUID.generate(), generation: 1},
               %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"},
               actor: ctx.actor
             )

    # The worker observes the stop on its next lease renewal. Keep the NVR ingest
    # read alive meanwhile, staying inside the first GOP (sequences 9..33 at most
    # span 7.5s, past the 5s renewal, with gaps well under the 1s NVR read timeout).
    Enum.reduce_while(Enum.slice(ctx.media.units, 8, 25), :ok, fn unit, :ok ->
      if Process.alive?(worker) and not :sys.get_state(worker).detached? do
        send(ctx.pipeline, {:media_chunk, unit})
        Process.sleep(300)
        {:cont, :ok}
      else
        {:halt, :ok}
      end
    end)

    assert {:ok, receipt} = Task.await(task, 20_000)
    assert receipt.status == :sealed_local
    assert receipt.storage_id == nvr.storage_id
    assert receipt.frames_sent in 8..33

    claim = recorder_claim(ctx)
    assert claim.state == :released
    assert claim.recorder_epoch == 1

    [block] = recording_blocks(ctx)
    assert block.block_key == receipt.block_key
    assert block.state == :open_local
  end

  test "NVRCapture rejects a capture timeout beyond the NVR client limit before taking the recorder fence",
       ctx do
    _owner = owner(ctx, 30_000)

    assert {:error, :invalid_capture_timeout} =
             NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
               actor: ctx.actor,
               timeout_ms: 600_000
             )

    assert {:error, :invalid_capture_timeout} =
             NVRCapture.capture_on_host(ctx.relay.id, "serviceradar-nvr-0", self(), 600_000, [])

    assert recorder_claim(ctx) == nil
    assert recording_blocks(ctx) == []
  end

  test "NVRCapture keeps renewing the recorder fence after a bound while the NVR seal response is outstanding",
       ctx do
    # The recorder lease is capped by the relay and owner leases; give both room
    # beyond the worker's 30s lease so a renewal can advance it.
    {:ok, _relay} =
      RelaySession.renew_lease(
        ctx.relay,
        %{lease_expires_at: DateTime.shift(DateTime.utc_now(), minute: 3)},
        actor: ctx.actor
      )

    owner = owner(ctx, 120_000)
    abs_tmp = Path.expand(ctx.tmp_dir)
    certs = write_nvr_mtls_certs(Path.join(abs_tmp, "holding-certs"))
    port = start_holding_tls_peer(certs, self())
    storage_id = Ecto.UUID.generate()
    token_file = Path.join(abs_tmp, "holding-token")
    config_file = Path.join(abs_tmp, "holding-client.json")
    File.write!(token_file, "synthetic-nvr-holding-token-0123456789")

    File.write!(
      config_file,
      Jason.encode!(%{
        "version" => 1,
        "port" => port,
        "ca_file" => certs.client_ca,
        "cert_file" => certs.client_cert,
        "key_file" => certs.client_key,
        "members" => %{
          "serviceradar-nvr-0" => %{"host" => "localhost", "storage_id" => storage_id}
        }
      })
    )

    task =
      Task.async(fn ->
        NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
          actor: ctx.actor,
          config_file: config_file,
          token_file: token_file,
          timeout_ms: 8_500,
          bounds: %{max_frames: 3, max_bytes: 8_388_608, max_duration_ms: 6_000}
        )
      end)

    worker = await_nvr_worker_attached(owner)
    Enum.each(Enum.take(ctx.media.units, 3), &send(ctx.pipeline, {:media_chunk, &1}))
    assert_receive :nvr_holding_peer_accepted, 5_000

    await_capture(
      fn -> if :sys.get_state(worker).detached?, do: {:ready, :ok}, else: :waiting end,
      System.monotonic_time(:millisecond) + 5_000
    )

    detached_lease = recorder_claim(ctx).lease_expires_at

    await_capture(
      fn ->
        claim = recorder_claim(ctx)

        if DateTime.after?(claim.lease_expires_at, detached_lease),
          do: {:ready, :ok},
          else: :waiting
      end,
      System.monotonic_time(:millisecond) + 9_000
    )

    assert recorder_claim(ctx).state == :active
    assert {:error, {:nvr_ingest_uncertain, details}} = Task.await(task, 30_000)
    assert details.storage_id == storage_id

    claim = recorder_claim(ctx)
    assert claim.state == :active
    assert claim.storage_id == storage_id
  end

  test "NVRCapture.once_source closes only a relay it opened when capture aborts before recorder start",
       ctx do
    abs_tmp = Path.expand(ctx.tmp_dir)
    certs = write_nvr_mtls_certs(Path.join(abs_tmp, "origin-certs"))
    token_file = Path.join(abs_tmp, "origin-token")
    config_file = Path.join(abs_tmp, "origin-client.json")
    File.write!(token_file, "synthetic-nvr-origin-token-0123456789")

    File.write!(
      config_file,
      Jason.encode!(%{
        "version" => 1,
        "port" => free_local_port(),
        "ca_file" => certs.client_ca,
        "cert_file" => certs.client_cert,
        "key_file" => certs.client_key,
        "members" => %{
          "serviceradar-nvr-0" => %{"host" => "localhost", "storage_id" => Ecto.UUID.generate()}
        }
      })
    )

    capture_opts = [
      config_file: config_file,
      token_file: token_file,
      timeout_ms: 300,
      control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
      dispatch_open: fn _agent, _payload, opts, _requester -> {:ok, opts[:command_id]} end
    ]

    shared_ctx = Fixtures.context()
    assert {:ok, shared} = Fixtures.open(shared_ctx)

    assert {:error, :capture_timeout} =
             NVRCapture.once_source(
               shared_ctx.source.id,
               shared_ctx.profile.id,
               "serviceradar-nvr-0",
               [actor: shared_ctx.actor] ++ capture_opts
             )

    assert [retained] = Fixtures.sessions(shared_ctx)
    assert retained.id == shared.id
    assert retained.status == shared.status

    own_ctx = Fixtures.context()

    assert {:error, :capture_timeout} =
             NVRCapture.once_source(
               own_ctx.source.id,
               own_ctx.profile.id,
               "serviceradar-nvr-0",
               [actor: own_ctx.actor] ++ capture_opts
             )

    assert [opened] = Fixtures.sessions(own_ctx)
    assert opened.status in [:closing, :closed, :failed]
  end

  test "NVRCapture.once_source closes a relay it opened when capture fails after the relay is hosted",
       ctx do
    nvr_ctx = Fixtures.context()
    nvr = setup_nvr_release(ctx.tmp_dir)
    parent = self()

    task =
      Task.async(fn ->
        NVRCapture.once_source(
          nvr_ctx.source.id,
          nvr_ctx.profile.id,
          "serviceradar-nvr-0",
          actor: nvr_ctx.actor,
          control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
          dispatch_open: fn _agent, payload, opts, _requester ->
            send(parent, {:nvr_relay_open_dispatched, payload.relay_session_id})
            {:ok, opts[:command_id]}
          end,
          config_file: nvr.client_config,
          token_file: nvr.token_file,
          timeout_ms: 15_000
        )
      end)

    assert_receive {:nvr_relay_open_dispatched, relay_id}, 5_000
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    assert {:ok, pending_relay} = RelaySession.get_by_id(relay_id, actor: nvr_ctx.actor)
    ingest_id = Ecto.UUID.generate()
    assert {:ok, active_relay} = Fixtures.activate(nvr_ctx, pending_relay, ingest_id)

    {:ok, %{pipeline_pid: pipeline}} =
      PipelineManager.open_session(%{
        relay_session_id: active_relay.id,
        media_ingest_id: ingest_id
      })

    on_exit(fn -> Membrane.Pipeline.terminate(pipeline, force?: true) end)

    assert {:error, :recording_disabled} = Task.await(task, 30_000)
    assert [closed] = Fixtures.sessions(nvr_ctx)
    assert closed.id == relay_id
    assert closed.status in [:closing, :closed, :failed]
  end

  test "NVRCapture returns a verified seal receipt when worker cleanup outlasts the exit wait",
       ctx do
    owner = owner(ctx, 30_000)
    nvr = setup_nvr_release(ctx.tmp_dir)
    _daemon = start_nvr_daemon(nvr)

    task =
      Task.async(fn ->
        NVRCapture.once_relay(ctx.relay.id, "serviceradar-nvr-0",
          actor: ctx.actor,
          config_file: nvr.client_config,
          token_file: nvr.token_file,
          exit_wait_ms: 150,
          bounds: %{max_frames: 5, max_bytes: 8_388_608, max_duration_ms: 6_000}
        )
      end)

    worker = await_nvr_worker_attached(owner)
    # Slower than the 150ms exit wait, faster than the worker's 2s cleanup timeout.
    _release_hook = capture_slow_recorder_release(600)
    worker_ref = Process.monitor(worker)
    Enum.each(Enum.take(ctx.media.units, 5), &send(ctx.pipeline, {:media_chunk, &1}))

    assert {:ok, receipt} = Task.await(task, 30_000)
    assert receipt.status == :sealed_local
    assert receipt.storage_id == nvr.storage_id
    assert receipt.frames_sent == 5

    assert_receive {:recorder_claim_released_by, ^worker}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 5_000
    assert recorder_claim(ctx).state == :released
  end

  defp await_nvr_worker_attached(owner) do
    await_capture(
      fn ->
        case Registry.lookup(
               ServiceRadarCoreElx.CameraRecording.Registry,
               {owner.id, owner.epoch}
             ) do
          [{worker, _}] ->
            case :sys.get_state(worker) do
              %{inbox: %{id: inbox_id}} when is_reference(inbox_id) -> {:ready, worker}
              _ -> :waiting
            end

          [] ->
            :waiting
        end
      end,
      System.monotonic_time(:millisecond) + 5_000
    )
  end

  defp setup_nvr_release(base_dir) do
    dir = Path.join(Path.expand(base_dir), "nvr-fixture")
    release_dir = Path.join(dir, "release")
    spool_dir = Path.join(dir, "spool")
    certs_dir = Path.join(dir, "certs")
    File.mkdir_p!(release_dir)
    File.mkdir_p!(spool_dir)
    File.chmod!(spool_dir, 0o700)

    tarball = Path.expand("../../elixir/serviceradar_nvr/serviceradar-nvr-release.tar.gz")

    assert {"", 0} =
             System.cmd("tar", ["-xzf", tarball, "-C", release_dir], stderr_to_stdout: true)

    storage_id = Ecto.UUID.generate()
    peer_storage_id = Ecto.UUID.generate()
    assert {:ok, _} = Storage.initialize(spool_dir, storage_id)

    certs = write_nvr_mtls_certs(certs_dir)
    ingest_port = free_local_port()
    health_port = free_local_port()
    unused_port = free_local_port()
    gate = Application.fetch_env!(:serviceradar_core, :nvr_recovery_gate)

    ingest_config = Path.join(dir, "ingest.json")
    token_file = Path.join(dir, "ingest-token")
    client_config = Path.join(dir, "client.json")
    token = "synthetic-nvr-recording-coordinator-token"
    File.write!(token_file, token)

    File.write!(
      ingest_config,
      Jason.encode!(%{
        "port" => ingest_port,
        "client_sha256" => certs.client_sha256,
        "cert_file" => certs.server_cert,
        "key_file" => certs.server_key,
        "ca_file" => certs.server_ca
      })
    )

    File.write!(
      client_config,
      Jason.encode!(%{
        "version" => 1,
        "port" => ingest_port,
        "ca_file" => certs.client_ca,
        "cert_file" => certs.client_cert,
        "key_file" => certs.client_key,
        "members" => %{
          "serviceradar-nvr-0" => %{"host" => "localhost", "storage_id" => storage_id},
          "serviceradar-nvr-1" => %{
            "host" => "localhost",
            "port" => unused_port,
            "storage_id" => peer_storage_id
          }
        }
      })
    )

    %{
      dir: dir,
      binary: Path.join(release_dir, "bin/serviceradar_nvr"),
      spool_dir: spool_dir,
      storage_id: storage_id,
      ingest_port: ingest_port,
      health_port: health_port,
      ingest_config: ingest_config,
      token_file: token_file,
      client_config: client_config,
      certs: certs,
      gate: gate
    }
  end

  defp start_nvr_daemon(nvr) do
    env = [
      {~c"HOME", String.to_charlist(nvr.dir)},
      {~c"TMPDIR", String.to_charlist(nvr.dir)},
      {~c"RELEASE_COOKIE", ~c"synthetic_nvr_cookie"},
      {~c"ERL_CRASH_DUMP", ~c"/dev/null"},
      {~c"SERVICERADAR_NVR_SPOOL_ROOT", String.to_charlist(nvr.spool_dir)},
      {~c"SERVICERADAR_NVR_STORAGE_ID", String.to_charlist(nvr.storage_id)},
      {~c"SERVICERADAR_NVR_RECOVERY_GENERATION", String.to_charlist(nvr.gate.generation)},
      {~c"SERVICERADAR_NVR_RECOVERY_STATE_FILE", String.to_charlist(nvr.gate.path)},
      {~c"SERVICERADAR_NVR_MAX_SESSIONS", ~c"2"},
      {~c"SERVICERADAR_NVR_HEALTH_PORT", String.to_charlist(Integer.to_string(nvr.health_port))},
      {~c"SERVICERADAR_NVR_INGEST_CONFIG_FILE", String.to_charlist(nvr.ingest_config)},
      {~c"SERVICERADAR_NVR_INGEST_TOKEN_FILE", String.to_charlist(nvr.token_file)}
    ]

    port =
      Port.open({:spawn_executable, nvr.binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env: env
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    daemon = %{port: port, os_pid: os_pid}
    on_exit(fn -> stop_nvr_daemon(daemon) end)
    await_nvr_ready(nvr, daemon)
    daemon
  end

  defp stop_nvr_daemon(%{port: port, os_pid: os_pid}) do
    if Port.info(port) != nil do
      _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        10_000 ->
          _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
          :ok
      end
    end
  end

  defp await_nvr_ready(nvr, %{port: port}) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    await_capture(
      fn ->
        if Port.info(port) == nil do
          flunk("serviceradar_nvr exited before becoming ready")
        end

        if nvr_health_ready?(nvr.health_port) and nvr_tls_ready?(nvr) do
          {:ready, :ok}
        else
          :waiting
        end
      end,
      deadline
    )
  end

  defp nvr_health_ready?(health_port) do
    case :gen_tcp.connect({127, 0, 0, 1}, health_port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :ok =
          :gen_tcp.send(
            sock,
            "GET /readyz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
          )

        resp = :gen_tcp.recv(sock, 0, 1_000)
        :gen_tcp.close(sock)
        match?({:ok, "HTTP/1.1 200" <> _}, resp)

      _ ->
        false
    end
  end

  defp nvr_tls_ready?(nvr) do
    ssl_opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacertfile: String.to_charlist(nvr.certs.client_ca),
      certfile: String.to_charlist(nvr.certs.client_cert),
      keyfile: String.to_charlist(nvr.certs.client_key),
      server_name_indication: ~c"localhost"
    ]

    case :ssl.connect(~c"localhost", nvr.ingest_port, ssl_opts, 500) do
      {:ok, sock} ->
        _ = :ssl.close(sock)
        true

      _ ->
        false
    end
  end

  defp export_nvr_block(nvr, block_key) do
    out_path = Path.join(nvr.dir, "#{block_key}.mp4")

    script = """
    {:ok, _} = Application.ensure_all_started(:serviceradar_nvr)
    block_id = System.fetch_env!("NVR_EXPORT_BLOCK_ID")
    out_path = System.fetch_env!("NVR_EXPORT_OUT_PATH")
    {:ok, [^block_id]} = ServiceRadarNVR.list_blocks()
    {:ok, descriptor_json} = ServiceRadarNVR.block_descriptor(block_id)
    digest = Base.encode16(:crypto.hash(:sha256, descriptor_json), case: :lower)
    %{"fragments" => fragments} = Jason.decode!(descriptor_json)
    {:ok, init} = ServiceRadarNVR.read_block(block_id, digest, :init)
    media =
      Enum.map(fragments, fn %{"sequence" => seq} ->
        {:ok, bytes} = ServiceRadarNVR.read_block(block_id, digest, {:fragment, seq})
        bytes
      end)
    File.write!(out_path, [init | media])
    """

    env = [
      {"HOME", nvr.dir},
      {"TMPDIR", nvr.dir},
      {"RELEASE_COOKIE", "synthetic_nvr_cookie"},
      {"ERL_CRASH_DUMP", "/dev/null"},
      {"SERVICERADAR_NVR_SPOOL_ROOT", nvr.spool_dir},
      {"SERVICERADAR_NVR_STORAGE_ID", nvr.storage_id},
      {"SERVICERADAR_NVR_RECOVERY_GENERATION", nvr.gate.generation},
      {"SERVICERADAR_NVR_RECOVERY_STATE_FILE", nvr.gate.path},
      {"SERVICERADAR_NVR_HEALTH_PORT", Integer.to_string(free_local_port())},
      {"NVR_EXPORT_BLOCK_ID", block_key},
      {"NVR_EXPORT_OUT_PATH", out_path}
    ]

    assert {output, 0} =
             System.cmd(nvr.binary, ["eval", script], env: env, stderr_to_stdout: true)

    assert File.exists?(out_path), "expected exported mp4, got output: #{output}"
    out_path
  end

  defp write_nvr_mtls_certs(dir) do
    File.mkdir_p!(dir)
    algorithm = [digest: :sha256, key: {:namedCurve, :secp256r1}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: algorithm,
          intermediates: [],
          peer: algorithm ++ [extensions: [san]]
        },
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    for {prefix, tls} <- [{"server", certs.server_config}, {"client", certs.client_config}] do
      {key_type, key_der} = tls[:key]

      File.write!(
        Path.join(dir, "#{prefix}.pem"),
        :public_key.pem_encode([{:Certificate, tls[:cert], :not_encrypted}])
      )

      File.write!(
        Path.join(dir, "#{prefix}-key.pem"),
        :public_key.pem_encode([{key_type, key_der, :not_encrypted}])
      )

      File.write!(
        Path.join(dir, "#{prefix}-ca.pem"),
        :public_key.pem_encode(Enum.map(tls[:cacerts], &{:Certificate, &1, :not_encrypted}))
      )
    end

    client_der = certs.client_config[:cert]

    %{
      server_cert: Path.join(dir, "server.pem"),
      server_key: Path.join(dir, "server-key.pem"),
      server_ca: Path.join(dir, "server-ca.pem"),
      client_cert: Path.join(dir, "client.pem"),
      client_key: Path.join(dir, "client-key.pem"),
      client_ca: Path.join(dir, "client-ca.pem"),
      client_sha256: Base.encode16(:crypto.hash(:sha256, client_der), case: :lower)
    }
  end

  defp start_dropping_tls_peer(certs, notify_pid) do
    {:ok, listen} = :ssl.listen(0, tls_server_opts(certs))
    {:ok, {_addr, port}} = :ssl.sockname(listen)

    pid =
      spawn(fn ->
        dropping_peer_loop(listen, notify_pid, 0)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      _ = :ssl.close(listen)
    end)

    port
  end

  defp dropping_peer_loop(listen, notify_pid, count) do
    case :ssl.transport_accept(listen, 10_000) do
      {:ok, transport} ->
        next_count = count + 1

        case :ssl.handshake(transport, 5_000) do
          {:ok, ssl_sock} ->
            _ = read_until_body_started(ssl_sock, <<>>)
            _ = :ssl.close(ssl_sock)
            send(notify_pid, {:nvr0_closed_mid_stream, next_count})

          _ ->
            :ok
        end

        dropping_peer_loop(listen, notify_pid, next_count)

      _ ->
        :ok
    end
  end

  defp read_until_body_started(ssl_sock, acc) do
    if String.contains?(acc, "\r\n\r\n") and byte_size(acc) > 350 do
      acc
    else
      case :ssl.recv(ssl_sock, 0, 5_000) do
        {:ok, chunk} -> read_until_body_started(ssl_sock, acc <> chunk)
        _ -> acc
      end
    end
  end

  defp start_holding_tls_peer(certs, notify_pid) do
    {:ok, listen} = :ssl.listen(0, tls_server_opts(certs))
    {:ok, {_addr, port}} = :ssl.sockname(listen)
    pid = spawn(fn -> holding_peer_accept(listen, notify_pid) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      _ = :ssl.close(listen)
    end)

    port
  end

  defp holding_peer_accept(listen, notify_pid) do
    with {:ok, transport} <- :ssl.transport_accept(listen, 10_000),
         {:ok, ssl_sock} <- :ssl.handshake(transport, 5_000) do
      send(notify_pid, :nvr_holding_peer_accepted)
      holding_peer_read(ssl_sock)
    end
  end

  defp holding_peer_read(ssl_sock) do
    case :ssl.recv(ssl_sock, 0, 30_000) do
      {:ok, _chunk} -> holding_peer_read(ssl_sock)
      _ -> :ok
    end
  end

  defp start_forbidding_tls_peer(certs, notify_pid) do
    {:ok, listen} = :ssl.listen(0, tls_server_opts(certs))
    {:ok, {_addr, port}} = :ssl.sockname(listen)

    pid =
      spawn(fn ->
        case :ssl.transport_accept(listen, 10_000) do
          {:ok, sock} ->
            _ = :ssl.close(sock)
            send(notify_pid, {:unexpected_nvr1_failover, port})

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      _ = :ssl.close(listen)
    end)

    port
  end

  defp tls_server_opts(certs) do
    [
      :binary,
      ip: {127, 0, 0, 1},
      active: false,
      reuseaddr: true,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacertfile: String.to_charlist(certs.server_ca),
      certfile: String.to_charlist(certs.server_cert),
      keyfile: String.to_charlist(certs.server_key)
    ]
  end

  defp free_local_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end

  defp decode_rawvideo(path) do
    args = [
      "-nostdin",
      "-v",
      "error",
      "-threads",
      "1",
      "-filter_threads",
      "1",
      "-i",
      path,
      "-f",
      "rawvideo",
      "-pix_fmt",
      "yuv420p",
      "-threads",
      "1",
      "-"
    ]

    assert {bytes, 0} = System.cmd(SyntheticCameraMedia.tool("ffmpeg"), args)
    bytes
  end
end
