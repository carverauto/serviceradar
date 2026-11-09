alias ServiceRadarRecording.Inbox
alias ServiceRadarRecording.Spool
alias ServiceRadarRecording.Storage

{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)
{:error, :bad_name} = :code.lib_dir(:serviceradar_core)
{:error, :bad_name} = :code.lib_dir(:postgrex)
{:error, :bad_name} = :code.lib_dir(:libcluster)

root = System.fetch_env!("SERVICERADAR_NVR_SPOOL_ROOT")
id = System.fetch_env!("NVR_TEST_EXPECTED_STORAGE_ID")
clock = %{clock_epoch: "synthetic-clock", timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}
identity = %{source_id: "synthetic-camera", profile: "recording", recorder_epoch: 1, block_sequence: 0}

case System.fetch_env!("NVR_TEST_MODE") do
  "record" ->
    # Admission must not initialize an unprovisioned volume.
    {:error, :storage_identity_missing} = ServiceRadarNVR.start_recording(identity, clock)
    false = File.exists?(Path.join(root, ".storage-id"))
    {:ok, _} = Storage.initialize(root, id)
    {:ok, worker, inbox} = ServiceRadarNVR.start_recording(identity, clock)
    {:error, {:already_started, ^worker}} = ServiceRadarNVR.start_recording(identity, clock)
    {:ok, other, _} = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-camera-2"}, clock)
    {:error, :max_children} = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-camera-3"}, clock)
    :ok = ServiceRadarNVR.stop(other)

    aud = <<0, 0, 0, 1, 9>>
    [<<>> | units] = :binary.split(File.read!(System.fetch_env!("NVR_TEST_H264")), aud, [:global])
    75 = length(units)

    for {payload, index} <- Enum.with_index(units) do
      sequence = index + 1

      :ok =
        Inbox.offer(inbox, %{
          payload: aud <> payload,
          pts: 90_000 + index * 6_000,
          dts: 90_000 + index * 6_000,
          sequence: sequence,
          codec: "h264",
          payload_format: "annexb",
          media_ingest_id: inbox.media_ingest_id
        })

      %{last_sequence: ^sequence} = ServiceRadarNVR.status(worker)
    end

    monitor = Process.monitor(worker)
    :ok = Inbox.finish(inbox)

    receive do
      {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} ->
        true = snapshot.sealed?
        true = snapshot.high_water > 0

        File.write!(
          System.fetch_env!("NVR_TEST_RECEIPT"),
          Jason.encode!(%{directory: snapshot.directory, identity: snapshot.identity})
        )
    after
      10_000 -> raise "missing sealed local receipt"
    end

    receive do
      {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
    after
      5_000 -> raise "recording worker did not retire"
    end

    {:error, :recording_closed} = Inbox.usable(inbox)

  "recover" ->
    %{"directory" => directory, "identity" => retained_identity} =
      Jason.decode!(File.read!(System.fetch_env!("NVR_TEST_RECEIPT")))

    {:ok, storage} = Storage.open(root, id)
    {:ok, spool} = Spool.recover(storage, directory, retained_identity)
    snapshot = Spool.snapshot(spool)
    true = snapshot.sealed?
    {:ok, init} = Spool.read_init(snapshot)

    media =
      Enum.map(snapshot.entries, fn entry ->
        {:ok, bytes} = Spool.read_fragment(snapshot, entry["sequence"])
        bytes
      end)

    File.write!(System.fetch_env!("NVR_TEST_MP4"), [init | media])

  "lifecycle" ->
    {:ok, _} = Storage.initialize(root, id)
    {:ok, worker, inbox} = ServiceRadarNVR.start_recording(identity, clock)
    monitor = Process.monitor(worker)

    receive do
      {:nvr_recording, ^worker, {:error, :lease_expired}} -> :ok
    after
      5_000 -> raise "deadline failed to retire idle recording"
    end

    receive do
      {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
    after
      5_000 -> raise "expired worker remained alive"
    end

    {:error, _} = Inbox.usable(inbox)
    parent = self()

    producer =
      spawn(fn ->
        {:ok, worker, inbox} = ServiceRadarNVR.start_recording(identity, clock)
        send(parent, {:started, worker, inbox})

        receive do
          :exit -> :ok
        end
      end)

    receive do
      {:started, worker, inbox} ->
        monitor = Process.monitor(worker)
        {:error, :not_recording_producer} = Inbox.finish(inbox)
        send(producer, :exit)

        receive do
          {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
        after
          5_000 -> raise "producer death did not retire recording"
        end

        {:error, _} = Inbox.usable(inbox)
    after
      5_000 -> raise "replacement could not acquire released slot"
    end
end

IO.puts("NVR_RELEASE_PROBE_OK")
