defmodule ServiceRadarCoreElx.CameraRecording.InboxTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRecording.Inbox
  alias ServiceRadarCoreElx.CameraRelay.Pipeline
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  setup do
    previous = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    storage = Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)
    on_exit(fn -> Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, previous) end)
    on_exit(fn -> Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, storage) end)
    :ok
  end

  test "slow recording consumers cannot enqueue beyond credits or interrupt live forwarding" do
    cases = [
      {[max_samples: 2, max_bytes: 64], 30_000, 2, :queue_full},
      {[max_samples: 8, max_bytes: 8], 30_000, 1, :queue_full},
      {[], -1, 0, :lease_expired},
      {[], 30_000, 0, :recording_ingest_mismatch}
    ]

    for {limits, remaining, accepted, reason} <- cases do
      {pipeline, relay, _viewer} = live_pipeline()
      {consumer, inbox} = attach_consumer(pipeline, relay, limits, remaining)
      assert {:error, :not_recording_producer} = Inbox.offer(inbox, chunk(0))

      for sequence <- 1..4 do
        unit = chunk(sequence)
        unit = if reason == :recording_ingest_mismatch, do: %{unit | media_ingest_id: "other-ingest"}, else: unit
        send(pipeline, {:media_chunk, unit})

        assert_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay, sequence: ^sequence}},
                       1_000
      end

      assert {:messages, messages} = Process.info(consumer, :messages)
      media = for {:recording_media, _id, unit} <- messages, do: unit.sequence
      assert media == Enum.take(1..4, accepted)
      assert [{:recording_rejected, _, ^reason}] = Enum.filter(messages, &match?({:recording_rejected, _, _}, &1))
      assert length(messages) == accepted + 1
      assert Process.alive?(pipeline)
    end
  end

  test "end of stream follows admitted units and the disabled gate refuses attachment" do
    {pipeline, relay, _viewer} = live_pipeline()
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, false)
    assert {:error, :recording_disabled} = ServiceRadarCoreElx.CameraRecording.Supervisor.start_recorder([])
    parent = self()

    {denied, denied_ref} =
      spawn_monitor(fn ->
        {:ok, inbox} = Inbox.new(pipeline, relay, "synthetic-ingest", System.monotonic_time(:millisecond) + 30_000)
        send(parent, {:denied, Membrane.Pipeline.call(pipeline, {:attach_recorder, inbox})})
      end)

    assert_receive {:denied, {:error, :recording_attach_refused}}
    assert_receive {:DOWN, ^denied_ref, :process, ^denied, :normal}
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)
    Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, nil)

    assert {:error, :recording_storage_identity_required} =
             ServiceRadarCoreElx.CameraRecording.Supervisor.start_recorder(
               owner: %{id: Ecto.UUID.generate(), epoch: 1, relay_session_id: relay},
               media_ingest_id: "synthetic-ingest",
               spool_root: "/unused-recording-root"
             )

    {consumer, inbox} = attach_consumer(pipeline, relay, [], 30_000)
    send(pipeline, {:media_chunk, chunk(1)})
    send(pipeline, {:media_chunk, chunk(2)})
    send(pipeline, :end_of_stream)
    assert false == Membrane.Pipeline.call(pipeline, {:webrtc_viewer_alive?, "no-viewer"})

    assert {:messages,
            [{:recording_media, id, %{sequence: 1}}, {:recording_media, id, %{sequence: 2}}, {:recording_end, id}]} =
             Process.info(consumer, :messages)

    assert id == inbox.id
  end

  defp live_pipeline do
    relay = "synthetic-relay-#{System.unique_integer([:positive])}"
    viewer = "synthetic-viewer"
    :ok = RelayPubSub.subscribe_viewer(relay, viewer)
    :ok = RelayPubSub.viewer_join(relay, viewer)
    :sys.get_state(ViewerRegistry)

    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start(Pipeline, relay_session_id: relay, media_ingest_id: "synthetic-ingest")

    on_exit(fn -> Membrane.Pipeline.terminate(pipeline, force?: true) end)
    {pipeline, relay, viewer}
  end

  defp attach_consumer(pipeline, relay, limits, remaining) do
    parent = self()

    consumer =
      spawn(fn ->
        {:ok, inbox} =
          Inbox.new(pipeline, relay, "synthetic-ingest", System.monotonic_time(:millisecond) + remaining, limits)

        :ok = Membrane.Pipeline.call(pipeline, {:attach_recorder, inbox})
        send(parent, {:attached, inbox})
        # Deliberately consume no media: the production admission gate must enforce
        # its limit before this process ever looks at its mailbox.
        receive do: (:stop -> Inbox.cancel(inbox))
      end)

    on_exit(fn -> send(consumer, :stop) end)
    assert_receive {:attached, inbox}, 1_000
    {consumer, inbox}
  end

  defp chunk(sequence) do
    %{
      sequence: sequence,
      media_ingest_id: "synthetic-ingest",
      payload: <<0, 0, 0, 1, 103, 66, 0, 30>>,
      pts: sequence * 6_000,
      dts: sequence * 6_000,
      codec: "h264",
      payload_format: "annexb",
      track_id: "video"
    }
  end
end
