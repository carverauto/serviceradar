alias ServiceRadarNVR.Capacity
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
  mode when mode in ["record", "interrupted"] ->
    # Admission must not initialize an unprovisioned volume.
    {:error, :storage_identity_missing} = ServiceRadarNVR.start_recording(identity, clock)
    {:error, :storage_identity_missing} = ServiceRadarNVR.list_blocks()
    {:error, :storage_identity_missing} = ServiceRadarNVR.recover_block("missing", identity)
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

    if mode == "interrupted" do
      # Exit the VM without finishing the inbox or running worker termination.
      IO.puts("NVR_RELEASE_PROBE_OK")
      System.halt(0)
    end

    monitor = Process.monitor(worker)
    :ok = Inbox.finish(inbox)

    receive do
      {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} ->
        true = snapshot.sealed?
        true = snapshot.high_water > 0

        File.write!(
          System.fetch_env!("NVR_TEST_RECEIPT"),
          Jason.encode!(%{
            directory: snapshot.directory,
            identity: snapshot.identity,
            block_bytes: ServiceRadarNVR.capacity() |> elem(1) |> Map.fetch!(:block_bytes)
          })
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

    # Same VM: the released block's retained bytes, not its reservation, are charged.
    {:ok, %{used_bytes: retained, reservations: 0, reserved_bytes: 0, block_bytes: block} = usage} =
      ServiceRadarNVR.capacity()

    true = retained > 0
    roomy = %{usage | available_bytes: usage.reserve_bytes + block}
    :ok = Capacity.admission(%{roomy | max_spool_bytes: retained + block})
    {:error, :nvr_spool_budget_exhausted} = Capacity.admission(%{roomy | max_spool_bytes: retained + block - 1})
    {:error, :nvr_spool_budget_exhausted} = Capacity.admission(%{roomy | max_spool_bytes: block})

    # Admitted exactly at the physical boundary, the worker may write its whole
    # block and stops only once the configured floor itself is breached.
    floor = usage.reserve_bytes
    {:error, :nvr_storage_pressure} = Capacity.admission(%{roomy | available_bytes: floor + block - 1})

    for written <- [0, 1, div(block, 2), block] do
      :ok = Capacity.writable(floor + block - written, floor)
    end

    {:error, :nvr_storage_pressure} = Capacity.writable(floor - 1, floor)
    {:error, :nvr_storage_pressure} = Capacity.writable(0, floor)

  "recover" ->
    %{"directory" => directory, "identity" => retained_identity} =
      Jason.decode!(File.read!(System.fetch_env!("NVR_TEST_RECEIPT")))

    # The new process must count retained media before reserving another block.
    # Python configured exactly one full-block budget: it would fit if empty.
    {:error, :nvr_spool_budget_exhausted} =
      ServiceRadarNVR.start_recording(%{identity | block_sequence: 1}, clock)

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

  mode when mode in ["rotation", "rotation_budget"] ->
    {:ok, _} = Storage.initialize(root, id)
    {:ok, %{block_bytes: block_bytes}} = ServiceRadarNVR.capacity()
    {:ok, worker, inbox} = ServiceRadarNVR.start_recording(identity, clock)
    monitor = Process.monitor(worker)
    aud = <<0, 0, 0, 1, 9>>
    [<<>> | units] = :binary.split(File.read!(System.fetch_env!("NVR_TEST_H264")), aud, [:global])
    510 = length(units)

    pushed =
      Enum.reduce_while(Enum.with_index(units), :ok, fn {payload, index}, :ok ->
        sequence = index + 1

        try do
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
          {:cont, :ok}
        catch
          :exit, _ -> {:halt, :stopped}
        end
      end)

    if mode == "rotation" do
      :ok = pushed
      :ok = Inbox.finish(inbox)
    end

    collect = fn collect, blocks ->
      receive do
        {:nvr_block_sealed, ^worker, %{snapshot: snapshot}} ->
          true = snapshot.sealed?
          collect.(collect, [snapshot | blocks])

        {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} when mode == "rotation" ->
          Enum.reverse([snapshot | blocks])

        {:nvr_recording, ^worker, {:error, :nvr_spool_budget_exhausted}} when mode == "rotation_budget" ->
          Enum.reverse(blocks)
      after
        10_000 -> raise "missing rotation result"
      end
    end

    blocks = collect.(collect, [])
    expected_sequences = if mode == "rotation", do: [0, 1, 2], else: [0]
    ^expected_sequences = Enum.map(blocks, & &1.identity["block_sequence"])
    expected_fragments = if mode == "rotation", do: [8, 8, 1], else: [8]
    ^expected_fragments = Enum.map(blocks, &length(&1.entries))
    true = Enum.all?(blocks, & &1.sealed?)
    expected_clock = Jason.decode!(Jason.encode!(clock))
    true = Enum.all?(blocks, &(&1.identity["clock"] == expected_clock))

    for [previous, next] <- blocks |> Enum.flat_map(& &1.entries) |> Enum.chunk_every(2, 1, :discard) do
      true = previous["start_ns"] + previous["duration_ns"] == next["start_ns"]
    end

    receive do
      {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
    after
      5_000 -> raise "rotating worker did not retire"
    end

    {:error, :recording_closed} = Inbox.usable(inbox)

    File.write!(
      System.fetch_env!("NVR_TEST_RECEIPT"),
      Jason.encode!(%{block_bytes: block_bytes, blocks: Enum.map(blocks, &Map.take(&1, [:directory, :identity]))})
    )

  "discover_rotation" ->
    # Restarted discovery has no notification, receipt file or expected identity.
    {:ok, block_ids} = ServiceRadarNVR.list_blocks()
    false = block_ids == []
    {:error, :invalid_block_id} = ServiceRadarNVR.sealed_block("../outside")

    blocks =
      Enum.map(block_ids, fn block_id ->
        {:ok, descriptor} = ServiceRadarNVR.block_descriptor(block_id)
        digest = Base.encode16(:crypto.hash(:sha256, descriptor), case: :lower)
        %{id: block_id, descriptor: descriptor, metadata: Jason.decode!(descriptor), digest: digest}
      end)

    for {block, index} <- blocks |> Enum.sort_by(& &1.metadata["identity"]["block_sequence"]) |> Enum.with_index() do
      {:ok, init} = ServiceRadarNVR.read_block(block.id, block.digest, :init)

      media =
        Enum.map(block.metadata["fragments"], fn entry ->
          {:ok, bytes} = ServiceRadarNVR.read_block(block.id, block.digest, {:fragment, entry["sequence"]})
          bytes
        end)

      File.write!(System.fetch_env!("NVR_TEST_MP4") <> ".#{index}", [init | media])
      File.write!(System.fetch_env!("NVR_TEST_MP4") <> ".#{index}.json", block.descriptor)
    end

    [block | _] = blocks
    wrong_digest = String.duplicate("0", 64)

    for selector <- [:init, {:fragment, 0}] do
      {:error, :descriptor_digest_mismatch} = ServiceRadarNVR.read_block(block.id, wrong_digest, selector)

      for invalid <- [nil, <<0::256>>, String.duplicate("0", 63), String.duplicate("A", 64), block.digest <> "\n"] do
        {:error, :invalid_descriptor_digest} = ServiceRadarNVR.read_block(block.id, invalid, selector)
      end
    end

    for selector <- [:media, {:fragment, -1}, {:fragment, "0"}, {:range, 0, 1}, "../outside"] do
      {:error, :invalid_media_selector} = ServiceRadarNVR.read_block(block.id, block.digest, selector)
    end

    {:error, :not_readable} =
      ServiceRadarNVR.read_block(block.id, block.digest, {:fragment, length(block.metadata["fragments"])})

    {:error, :invalid_block_id} = ServiceRadarNVR.read_block("../outside", block.digest, :init)

  "recover_interrupted" ->
    {:ok, [block_id]} = ServiceRadarNVR.list_blocks()
    expected = Map.put(identity, :clock, clock)
    directory = Path.join(root, block_id)
    read_files = fn -> Map.new(File.ls!(directory), &{&1, File.read!(Path.join(directory, &1))}) end
    before = read_files.()

    {:ok, worker, _} = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-other"}, clock)
    {:error, :nvr_recordings_active} = ServiceRadarNVR.recover_block(block_id, expected)
    ^before = read_files.()
    monitor = Process.monitor(worker)
    :ok = ServiceRadarNVR.stop(worker)

    receive do
      {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
    after
      5_000 -> raise "writer did not retire before recovery"
    end

    {:ok, %{reservations: 0}} = ServiceRadarNVR.capacity()
    {:error, :identity_or_header_mismatch} = ServiceRadarNVR.recover_block(block_id, %{expected | recorder_epoch: 2})
    {:error, :invalid_block_id} = ServiceRadarNVR.recover_block("../outside", expected)
    ^before = read_files.()
    {:ok, snapshot} = ServiceRadarNVR.recover_block(block_id, expected)
    true = snapshot.sealed?
    [_, _] = snapshot.entries
    sealed_files = read_files.()
    {:ok, ^snapshot} = ServiceRadarNVR.recover_block(block_id, expected)
    ^sealed_files = read_files.()
    {:ok, ^snapshot} = ServiceRadarNVR.sealed_block(block_id)

  mode when mode in ["discover_unresolved", "recover_unresolved"] ->
    {:ok, [block_id]} = ServiceRadarNVR.list_blocks()

    result =
      if mode == "recover_unresolved",
        do: ServiceRadarNVR.recover_block(block_id, Map.put(identity, :clock, clock)),
        else: ServiceRadarNVR.sealed_block(block_id)

    if mode == "discover_unresolved" do
      ^result = ServiceRadarNVR.block_descriptor(block_id)

      for selector <- [:init, {:fragment, 0}] do
        ^result = ServiceRadarNVR.read_block(block_id, String.duplicate("0", 64), selector)
      end
    end

    {:error, reason} = result
    expected = System.fetch_env!("NVR_TEST_RECOVERY_ERROR")
    ^expected = Atom.to_string(reason)

  "capacity" ->
    {:ok, _} = Storage.initialize(root, id)
    parent = self()

    producers =
      for index <- 1..3 do
        spawn(fn ->
          receive do
            :start -> :ok
          end

          result = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-camera-#{index}"}, clock)
          send(parent, {:admitted, self(), result})

          receive do
            :stop ->
              case result do
                {:ok, worker, _} -> ServiceRadarNVR.stop(worker)
                _ -> :ok
              end
          end
        end)
      end

    Enum.each(producers, &send(&1, :start))

    results =
      for _ <- producers do
        receive do
          {:admitted, producer, result} -> {producer, result}
        after
          10_000 -> raise "concurrent admission did not return"
        end
      end

    [{_producer, {:ok, worker, inbox}}] = Enum.filter(results, &match?({_, {:ok, _, _}}, &1))
    2 = Enum.count(results, &match?({_, {:error, :nvr_spool_budget_exhausted}}, &1))
    {:ok, %{used_bytes: 0, reserved_bytes: reserved}} = ServiceRadarNVR.capacity()
    true = reserved > 0
    monitor = Process.monitor(worker)

    # Lost accounting must retire its dependents before accepting new work.
    Process.exit(Process.whereis(Capacity), :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      5_000 -> raise "capacity restart left an admitted writer alive"
    end

    {:error, _} = Inbox.usable(inbox)
    Enum.each(producers, &send(&1, :stop))

    wait = fn wait, remaining ->
      if remaining == 0, do: raise("replacement reservation manager did not become available")

      result =
        try do
          ServiceRadarNVR.start_recording(identity, clock)
        catch
          :exit, _ -> {:error, :restarting}
        end

      case result do
        {:ok, replacement, _} ->
          replacement

        {:error, _} ->
          Process.sleep(10)
          wait.(wait, remaining - 1)
      end
    end

    replacement = wait.(wait, 100)
    monitor = Process.monitor(replacement)
    Process.exit(replacement, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^replacement, :killed} -> :ok
    after
      5_000 -> raise "writer kill did not finish"
    end

    replacement = wait.(wait, 100)
    :ok = ServiceRadarNVR.stop(replacement)

  "pressure" ->
    {:ok, _} = Storage.initialize(root, id)
    {:error, :nvr_storage_pressure} = ServiceRadarNVR.start_recording(identity, clock)
    {:ok, %{used_bytes: 0, reserved_bytes: 0}} = ServiceRadarNVR.capacity()

  "inventory" ->
    {:error, :nvr_inventory_unavailable} = ServiceRadarNVR.start_recording(identity, clock)
    {:error, :nvr_inventory_unavailable} = ServiceRadarNVR.capacity()
    {:error, :nvr_inventory_unavailable} = ServiceRadarNVR.list_blocks()

  "inventory_limit" ->
    {:error, :nvr_inventory_limit} = ServiceRadarNVR.start_recording(identity, clock)
    {:ok, %{blocks: 4096, used_bytes: 0, reserved_bytes: 0}} = ServiceRadarNVR.capacity()
    {:ok, blocks} = ServiceRadarNVR.list_blocks()
    4096 = length(blocks)

  "discovery_limit" ->
    {:error, :nvr_inventory_limit} = ServiceRadarNVR.list_blocks()

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
