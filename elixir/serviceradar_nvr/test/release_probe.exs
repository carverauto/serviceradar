alias ServiceRadarNVR.Capacity
alias ServiceRadarNVR.Reads
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
    66_048 = usage.publication_reserved_bytes
    66_048 = usage.publication_block_bytes
    needed = block + 2 * 66_048
    roomy = %{usage | available_bytes: usage.reserve_bytes + needed}
    :ok = Capacity.admission(%{roomy | max_spool_bytes: retained + needed})
    {:error, :nvr_spool_budget_exhausted} = Capacity.admission(%{roomy | max_spool_bytes: retained + needed - 1})
    {:error, :nvr_spool_budget_exhausted} = Capacity.admission(%{roomy | max_spool_bytes: block})

    # Admitted exactly at the physical boundary, the worker may write its whole
    # block while leaving both blocks' publication records and the physical floor.
    floor = usage.reserve_bytes + 2 * 66_048
    {:error, :nvr_storage_pressure} = Capacity.admission(%{roomy | available_bytes: floor + block - 1})

    for written <- [0, 1, div(block, 2), block] do
      :ok = Capacity.writable(floor + block - written, floor)
    end

    {:error, :nvr_storage_pressure} = Capacity.writable(floor - 1, floor)
    {:error, :nvr_storage_pressure} = Capacity.writable(0, floor)

  "publication_headroom" ->
    {:ok, %{publication_reserved_bytes: 66_048}} = ServiceRadarNVR.capacity()

    {:error, :nvr_spool_budget_exhausted} =
      ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-next-camera"}, clock)

  "publication_headroom_released" ->
    {:ok, %{publication_reserved_bytes: 0}} = ServiceRadarNVR.capacity()
    {:ok, worker, _} = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-next-camera"}, clock)
    {:ok, %{publication_reserved_bytes: 66_048}} = ServiceRadarNVR.capacity()
    :ok = ServiceRadarNVR.stop(worker)

  mode
  when mode in [
         "publication_prepare",
         "publication_retry",
         "publication_budget",
         "publication_pressure",
         "publication_error"
       ] ->
    {:ok, [block_id]} = ServiceRadarNVR.list_blocks()

    reference = %{
      operation_id: "00000000-0000-4000-8000-000000000021",
      recording_block_id: "00000000-0000-4000-8000-000000000022",
      descriptor_sha256: System.fetch_env!("NVR_TEST_DESCRIPTOR_SHA256")
    }

    path = Path.join([root, block_id, "publication.json"])

    case mode do
      "publication_prepare" ->
        {:ok, %{used_bytes: before_bytes}} = ServiceRadarNVR.capacity()
        {:error, :enoent} = ServiceRadarNVR.publication_intent(block_id)
        {:error, :invalid_publication_reference} = ServiceRadarNVR.prepare_publication(block_id, %{})

        {:error, :descriptor_digest_mismatch} =
          ServiceRadarNVR.prepare_publication(block_id, %{reference | descriptor_sha256: String.duplicate("0", 64)})

        false = File.exists?(path)

        # Publication of a sealed block is allowed while another recording is active.
        {:ok, worker, _} = ServiceRadarNVR.start_recording(%{identity | block_sequence: 1}, clock)
        {:ok, bytes} = ServiceRadarNVR.prepare_publication(block_id, reference)
        true = Process.alive?(worker)
        monitor = Process.monitor(worker)
        :ok = ServiceRadarNVR.stop(worker)

        receive do
          {:DOWN, ^monitor, :process, ^worker, :normal} -> :ok
        after
          5_000 -> raise "writer did not stop"
        end

        {:ok, ^bytes} = ServiceRadarNVR.prepare_publication(block_id, reference)
        {:ok, ^bytes} = ServiceRadarNVR.prepare_publication(block_id, reference)
        {:ok, ^bytes} = ServiceRadarNVR.publication_intent(block_id)
        ^bytes = File.read!(path)
        {:ok, %{used_bytes: after_bytes, publication_reserved_bytes: 512}} = ServiceRadarNVR.capacity()
        true = after_bytes == before_bytes + byte_size(bytes)

        for key <- [:operation_id, :recording_block_id] do
          {:error, :publication_intent_conflict} =
            ServiceRadarNVR.prepare_publication(
              block_id,
              Map.put(reference, key, "00000000-0000-4000-8000-000000000023")
            )

          ^bytes = File.read!(path)
        end

      "publication_retry" ->
        bytes = File.read!(path)
        {:ok, ^bytes} = ServiceRadarNVR.publication_intent(block_id)
        {:ok, ^bytes} = ServiceRadarNVR.prepare_publication(block_id, reference)
        {:ok, descriptor} = ServiceRadarNVR.block_descriptor(block_id)
        %{"descriptor" => document} = Jason.decode!(bytes)
        ^document = Jason.decode!(descriptor)

      "publication_budget" ->
        {:error, :nvr_spool_budget_exhausted} = ServiceRadarNVR.prepare_publication(block_id, reference)
        false = File.exists?(path)

      "publication_pressure" ->
        {:error, :nvr_storage_pressure} = ServiceRadarNVR.prepare_publication(block_id, reference)
        false = File.exists?(path)

      "publication_error" ->
        {:error, _} = ServiceRadarNVR.publication_intent(block_id)
        {:error, _} = ServiceRadarNVR.prepare_publication(block_id, reference)
    end

  mode
  when mode in [
         "publication_ack_store",
         "publication_ack_retry",
         "publication_ack_error",
         "publication_ack_input_error",
         "publication_ack_budget",
         "publication_ack_pressure"
       ] ->
    block_id = System.fetch_env!("NVR_TEST_BLOCK_ID")
    bytes = File.read!(System.fetch_env!("NVR_TEST_ACK"))
    path = Path.join([root, block_id, "publication-ack.json"])

    case mode do
      "publication_ack_store" ->
        {:error, :enoent} = ServiceRadarNVR.publication_acknowledgement(block_id)
        {:ok, %{used_bytes: before_bytes}} = ServiceRadarNVR.capacity()
        {:ok, ^bytes} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)
        {:ok, ^bytes} = ServiceRadarNVR.publication_acknowledgement(block_id)
        {:ok, %{used_bytes: after_bytes, publication_reserved_bytes: 0}} = ServiceRadarNVR.capacity()
        true = after_bytes == before_bytes + byte_size(bytes)

      "publication_ack_retry" ->
        {:ok, ^bytes} = ServiceRadarNVR.publication_acknowledgement(block_id)
        {:ok, ^bytes} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)

      "publication_ack_error" ->
        {:error, _} = ServiceRadarNVR.publication_acknowledgement(block_id)
        {:error, _} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)

      "publication_ack_input_error" ->
        {:error, :invalid_publication_acknowledgement} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)

      "publication_ack_budget" ->
        {:error, :nvr_spool_budget_exhausted} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)
        false = File.exists?(path)

      "publication_ack_pressure" ->
        {:error, :nvr_storage_pressure} = ServiceRadarNVR.acknowledge_publication(block_id, bytes)
        false = File.exists?(path)
    end

  "publication_page_setup" ->
    {:ok, [pending, accepted, _unprepared]} = ServiceRadarNVR.list_blocks()

    for {block_id, index} <- Enum.with_index([pending, accepted], 1) do
      {:ok, descriptor} = ServiceRadarNVR.block_descriptor(block_id)

      reference = %{
        operation_id: "00000000-0000-4000-8000-00000000003#{index}",
        recording_block_id: "00000000-0000-4000-8000-00000000004#{index}",
        descriptor_sha256: Base.encode16(:crypto.hash(:sha256, descriptor), case: :lower)
      }

      {:ok, intent} = ServiceRadarNVR.prepare_publication(block_id, reference)

      if block_id == accepted do
        {:ok, ack} = ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement.encode(intent)
        {:ok, ^ack} = ServiceRadarNVR.acknowledge_publication(block_id, ack)
      end
    end

  "publication_page" ->
    {:ok, block_ids} = ServiceRadarNVR.list_blocks()
    [first | _] = block_ids

    {:ok, %{storage_id: ^id, entries: [%{block_id: ^first}], next_cursor: cursor}} =
      ServiceRadarNVR.publication_page()

    %{storage_id: ^id, after_block_id: ^first} = cursor
    File.write!(System.fetch_env!("NVR_TEST_RECEIPT"), Jason.encode!(cursor))

    for limit <- [0, -1, 17, "1", nil] do
      {:error, :invalid_publication_page_limit} = ServiceRadarNVR.publication_page(nil, limit)
    end

    for invalid <- ["../outside", %{}, %{cursor | after_block_id: "../outside"}] do
      {:error, :invalid_publication_cursor} = ServiceRadarNVR.publication_page(invalid)
    end

    {:error, :publication_cursor_storage_mismatch} =
      ServiceRadarNVR.publication_page(%{cursor | storage_id: "00000000-0000-4000-8000-000000000099"})

    walk = fn walk, cursor, entries ->
      {:ok, %{storage_id: ^id, entries: [entry], next_cursor: next}} = ServiceRadarNVR.publication_page(cursor)
      if next, do: walk.(walk, next, [entry | entries]), else: Enum.reverse([entry | entries])
    end

    entries = walk.(walk, nil, [])
    ^block_ids = Enum.map(entries, & &1.block_id)
    {:ok, %{entries: ^entries, next_cursor: nil}} = ServiceRadarNVR.publication_page(nil, 16)
    end_cursor = %{storage_id: id, after_block_id: List.last(block_ids)}
    {:ok, %{entries: [], next_cursor: nil}} = ServiceRadarNVR.publication_page(end_cursor)

    output =
      Enum.map(entries, fn
        %{reason: reason} = entry -> %{entry | reason: inspect(reason)}
        entry -> entry
      end)

    File.write!(System.fetch_env!("NVR_TEST_MP4") <> ".pages.json", Jason.encode!(output))

  "publication_page_resume" ->
    %{"storage_id" => storage_id, "after_block_id" => after_id} =
      Jason.decode!(File.read!(System.fetch_env!("NVR_TEST_RECEIPT")))

    {:ok, [_first | remaining]} = ServiceRadarNVR.list_blocks()

    {:ok, %{entries: entries, next_cursor: nil}} =
      ServiceRadarNVR.publication_page(%{storage_id: storage_id, after_block_id: after_id}, 16)

    ^remaining = Enum.map(entries, & &1.block_id)

  "publication_concurrent" ->
    block_id = System.fetch_env!("NVR_TEST_BLOCK_ID")

    reference = %{
      operation_id: "00000000-0000-4000-8000-000000000021",
      recording_block_id: "00000000-0000-4000-8000-000000000022",
      descriptor_sha256: System.fetch_env!("NVR_TEST_DESCRIPTOR_SHA256")
    }

    parent = self()

    # OTP debug events let the test pause the real task while it waits for its
    # reservation call. No fake filesystem, clock or production injection hook.
    pause = fn operation, hold ->
      hook = fn
        _, {:in, {:"$gen_call", {caller, _}, _}}, _ ->
          if caller in Task.Supervisor.children(ServiceRadarNVR.PublicationTasks) do
            send(parent, {:publication_waiting, caller})

            receive do
              {:publication_paused, ^caller} -> :done
            after
              10_000 -> raise "publication pause handshake failed"
            end
          else
            :waiting
          end

        state, _, _ ->
          state
      end

      :ok = :sys.install(Capacity, {hook, :waiting})
      caller = spawn(fn -> send(parent, {:publication_finished, self(), operation.()}) end)

      receive do
        {:publication_waiting, task} ->
          hold.(task)
          send(Capacity, {:publication_paused, task})
          {caller, task}
      after
        5_000 -> raise "publication did not reach reservation"
      end
    end

    suspend = fn task -> true = :erlang.suspend_process(task) end
    {publisher, task} = pause.(fn -> ServiceRadarNVR.prepare_publication(block_id, reference) end, suspend)
    {:ok, %{publication_operations: 1, publication_write_reserved_bytes: pending}} = ServiceRadarNVR.capacity()
    true = pending > 0
    {:ok, %{publication_reserved_bytes: total}} = ServiceRadarNVR.capacity()
    true = total == 66_048 + pending
    {:error, :nvr_publication_capacity} = ServiceRadarNVR.prepare_publication(block_id, reference)
    {:error, :nvr_publication_capacity} = ServiceRadarNVR.recover_block(block_id, identity)
    false = File.exists?(Path.join([root, block_id, "publication.json"]))

    # A stalled metadata write must not block admission, frame checks or rotation.
    {:ok, worker, inbox} = ServiceRadarNVR.start_recording(%{identity | source_id: "synthetic-concurrent"}, clock)
    aud = <<0, 0, 0, 1, 9>>
    [<<>> | units] = :binary.split(File.read!(System.fetch_env!("NVR_TEST_H264")), aud, [:global])
    510 = length(units)

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

    %{block_sequence: 1} = ServiceRadarNVR.status(worker)
    {:ok, %{publication_operations: 1, publication_write_reserved_bytes: ^pending}} = ServiceRadarNVR.capacity()
    true = :erlang.resume_process(task)

    intent =
      receive do
        {:publication_finished, ^publisher, {:ok, bytes}} -> bytes
      after
        5_000 -> raise "publication did not finish"
      end

    {:ok, ack} = ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement.encode(intent)
    {:ok, ^ack} = ServiceRadarNVR.acknowledge_publication(block_id, ack)
    {:ok, %{publication_operations: 0, publication_write_reserved_bytes: 0}} = ServiceRadarNVR.capacity()
    # The task's DOWN may reach the observer before the capacity owner.
    wait = fn wait, attempts ->
      if attempts == 0, do: raise("publication capacity did not recover")

      case ServiceRadarNVR.acknowledge_publication(block_id, ack) do
        {:ok, ^ack} ->
          :ok

        {:error, reason} when reason in [:nvr_publication_capacity, :nvr_publication_unavailable] ->
          Process.sleep(10)
          wait.(wait, attempts - 1)

        other ->
          raise "unexpected publication recovery: #{inspect(other)}"
      end
    end

    # A reservation reply delayed past GenServer's default call timeout is
    # bounded by the task deadline, not a shorter internal timer.
    delay = fn _task -> Process.sleep(6_000) end
    {slow_caller, _slow_task} = pause.(fn -> ServiceRadarNVR.acknowledge_publication(block_id, ack) end, delay)

    receive do
      {:publication_finished, ^slow_caller, {:ok, ^ack}} -> :ok
      {:publication_finished, ^slow_caller, other} -> raise "delayed reservation failed: #{inspect(other)}"
    after
      30_000 -> raise "delayed reservation did not finish"
    end

    # Failure of the independent publication supervisor must not retire capture.
    {failed_caller, failed_task} = pause.(fn -> ServiceRadarNVR.acknowledge_publication(block_id, ack) end, suspend)
    task_monitor = Process.monitor(failed_task)
    Process.exit(Process.whereis(ServiceRadarNVR.PublicationTasks), :kill)

    receive do
      {:DOWN, ^task_monitor, :process, ^failed_task, _} -> :ok
    after
      5_000 -> raise "publication supervisor left its task alive"
    end

    receive do
      {:publication_finished, ^failed_caller, {:error, :nvr_publication_unavailable}} -> :ok
    after
      5_000 -> raise "publication failure was not returned"
    end

    %{last_sequence: 510, block_sequence: 1} = ServiceRadarNVR.status(worker)
    :ok = wait.(wait, 100)
    :ok = Inbox.finish(inbox)

    collect = fn collect, paths ->
      receive do
        {:nvr_block_sealed, ^worker, %{snapshot: snapshot}} -> collect.(collect, [snapshot.directory | paths])
        {:nvr_recording, ^worker, {:ok, %{snapshot: snapshot}}} -> Enum.reverse([snapshot.directory | paths])
      after
        5_000 -> raise "concurrent recording failed to seal"
      end
    end

    [_, _, _] = paths = collect.(collect, [])
    File.write!(System.fetch_env!("NVR_TEST_RECEIPT"), Jason.encode!(paths))

    # Caller loss does not remove the task deadline or free its admission slot.
    {orphan, abandoned} = pause.(fn -> ServiceRadarNVR.acknowledge_publication(block_id, ack) end, suspend)
    monitor = Process.monitor(abandoned)
    Process.exit(orphan, :kill)
    {:error, :nvr_publication_capacity} = ServiceRadarNVR.prepare_publication(block_id, reference)

    receive do
      {:DOWN, ^monitor, :process, ^abandoned, {:shutdown, :nvr_publication_timeout}} -> :ok
    after
      32_000 -> raise "abandoned publication survived its deadline"
    end

    :ok = wait.(wait, 100)
    {:ok, ^intent} = ServiceRadarNVR.publication_intent(block_id)
    {:ok, ^ack} = ServiceRadarNVR.publication_acknowledgement(block_id)
    {_caller, retiring_task} = pause.(fn -> ServiceRadarNVR.acknowledge_publication(block_id, ack) end, suspend)
    retiring_monitor = Process.monitor(retiring_task)
    Process.exit(Process.whereis(Capacity), :kill)

    receive do
      {:DOWN, ^retiring_monitor, :process, ^retiring_task, _} -> :ok
    after
      5_000 -> raise "lost capacity accounting left publication work alive"
    end

  "publication_storage_binding" ->
    # Preparation is the first API call in this VM: it must retain the opened
    # handle even on an exact retry, rather than silently reopening replacement.
    block_id = System.fetch_env!("NVR_TEST_BLOCK_ID")

    reference = %{
      operation_id: "00000000-0000-4000-8000-000000000021",
      recording_block_id: "00000000-0000-4000-8000-000000000022",
      descriptor_sha256: System.fetch_env!("NVR_TEST_DESCRIPTOR_SHA256")
    }

    {:ok, _} = ServiceRadarNVR.prepare_publication(block_id, reference)
    marker = Path.join(root, ".storage-id")
    replacement = marker <> ".replacement"
    File.write!(replacement, File.read!(marker))
    File.chmod!(replacement, 0o600)
    File.rename!(replacement, marker)
    {:error, :storage_changed} = ServiceRadarNVR.prepare_publication(block_id, reference)

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

    {:ok, %{reservations: 0, publication_reserved_bytes: pending}} = ServiceRadarNVR.capacity()
    true = pending == length(blocks) * 66_048

    File.write!(
      System.fetch_env!("NVR_TEST_RECEIPT"),
      Jason.encode!(%{block_bytes: block_bytes, blocks: Enum.map(blocks, &Map.take(&1, [:directory, :identity]))})
    )

  "discover_rotation" ->
    # Restarted discovery has no notification, receipt file or expected identity.
    {:ok, block_ids} = ServiceRadarNVR.list_blocks()
    false = block_ids == []
    {:ok, %{publication_reserved_bytes: pending}} = ServiceRadarNVR.capacity()
    true = pending == length(block_ids) * 66_048
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

  "read_admission" ->
    {:ok, _} = Storage.initialize(root, id)
    parent = self()

    # Exercise the read executor's admission/lifetime contract with held work;
    # public discovery/media calls below must compete for these same slots.
    start_read = fn tag ->
      caller =
        spawn(fn ->
          result =
            Reads.run(fn ->
              send(parent, {:read_entered, tag, self()})

              receive do
                :release -> {:ok, tag}
              end
            end)

          send(parent, {:read_result, tag, result})
        end)

      receive do
        {:read_entered, ^tag, task} -> {caller, task}
      after
        5_000 -> raise "read was not admitted"
      end
    end

    await_result = fn tag, expected ->
      receive do
        {:read_result, ^tag, ^expected} -> :ok
      after
        13_000 -> raise "missing read result for #{tag}"
      end
    end

    wait_readable = fn wait, remaining ->
      if remaining == 0, do: raise("read capacity was not released")

      case ServiceRadarNVR.list_blocks() do
        {:ok, []} ->
          :ok

        {:error, _} ->
          Process.sleep(10)
          wait.(wait, remaining - 1)
      end
    end

    held = for tag <- 1..4, do: {tag, start_read.(tag)}
    digest = String.duplicate("0", 64)
    {:error, :nvr_read_capacity} = ServiceRadarNVR.list_blocks()
    {:error, :nvr_read_capacity} = ServiceRadarNVR.publication_page()
    {:error, :nvr_read_capacity} = ServiceRadarNVR.sealed_block(digest)
    {:error, :nvr_read_capacity} = ServiceRadarNVR.block_descriptor(digest)
    {:error, :nvr_read_capacity} = ServiceRadarNVR.read_block(digest, digest, :init)
    {:error, :nvr_read_capacity} = ServiceRadarNVR.read_block(digest, digest, {:fragment, 0})
    {:error, :invalid_descriptor_digest} = ServiceRadarNVR.read_block(digest, nil, :init)
    {:error, :invalid_media_selector} = ServiceRadarNVR.read_block(digest, digest, :media)

    # Saturation does not consume a writer reservation or block its admission.
    {:ok, writer, _} = ServiceRadarNVR.start_recording(identity, clock)
    [{1, {_caller, killed}} | rest] = held
    Process.exit(killed, :kill)
    :ok = await_result.(1, {:error, :nvr_read_unavailable})

    for {tag, {_caller, task}} <- rest do
      send(task, :release)
      :ok = await_result.(tag, {:ok, tag})
    end

    :ok = wait_readable.(wait_readable, 100)

    {_caller, task} = start_read.(:restart)
    task_monitor = Process.monitor(task)
    Process.exit(Process.whereis(ServiceRadarNVR.ReadTasks), :kill)
    :ok = await_result.(:restart, {:error, :nvr_read_unavailable})

    receive do
      {:DOWN, ^task_monitor, :process, ^task, _} -> :ok
    after
      3_000 -> raise "read supervisor restart left old work alive"
    end

    :ok = wait_readable.(wait_readable, 100)
    true = Process.alive?(writer)
    {:ok, %{reservations: 1}} = ServiceRadarNVR.capacity()
    :ok = ServiceRadarNVR.stop(writer)

    {_caller, _task} = start_read.(:deadline)
    {orphan_caller, orphan_task} = start_read.(:orphan)
    orphan_monitor = Process.monitor(orphan_task)
    Process.exit(orphan_caller, :kill)
    :ok = await_result.(:deadline, {:error, :nvr_read_timeout})

    receive do
      {:DOWN, ^orphan_monitor, :process, ^orphan_task, {:shutdown, :nvr_read_timeout}} -> :ok
    after
      3_000 -> raise "caller loss left read work alive beyond its deadline"
    end

    :ok = wait_readable.(wait_readable, 100)

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
