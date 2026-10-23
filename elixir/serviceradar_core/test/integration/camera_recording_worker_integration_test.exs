defmodule ServiceRadar.Camera.RecordingWorkerIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRecording.Worker
  alias ServiceRadarCoreElx.CameraRelay.Pipeline
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    previous = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

    on_exit(fn ->
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, previous)
    end)

    start_supervised!(RecordingSupervisor)
    start_supervised!(ViewerRegistry)
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

    {:ok, _supervisor, pipeline} = Membrane.Pipeline.start(Pipeline, relay_session_id: relay.id)
    on_exit(fn -> Membrane.Pipeline.terminate(pipeline, force?: true) end)
    root = Path.join(ctx.tmp_dir, "spool")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    media = SyntheticCameraMedia.generate(ctx.tmp_dir, "source")

    %{
      source: source,
      profile: profile,
      relay: relay,
      pipeline: pipeline,
      actor: actor,
      root: root,
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
    assert snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert List.last(snapshot.entries)["tail_duration_source"] == "previous_sample"
    assert {:ok, recovered} = Spool.recover(snapshot.directory, snapshot.identity)
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
    assert File.ls!(ctx.root) == []
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
        [owner: owner, pipeline: ctx.pipeline, spool_root: ctx.root, notify: self()] ++ opts
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
