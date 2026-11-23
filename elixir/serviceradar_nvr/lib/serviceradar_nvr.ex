defmodule ServiceRadarNVR do
  @moduledoc """
  Local service boundary for a finite recording session with bounded local blocks.

  Only trusted code in this VM may call this API. It is not an enrollment,
  assignment or offline-authority protocol. The optional private TLS ingress adapts authenticated finite streams to this API;
  source assignment remains the trusted coordinator's responsibility.
  The caller is the sole producer and owns the returned bounded Inbox; media
  enters through Inbox.offer/2 and ends through Inbox.finish/1. Terminal results
  arrive as `{:nvr_recording, pid, result}`. A sealed local snapshot is not a
  catalog, archive or playback receipt.

  Full blocks produce `{:nvr_block_sealed, pid, receipt}` before admission of
  their successor. The terminal success contains the final block. These local
  notifications are not a durable outbox; retained journals are recovery evidence.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarNVR.Publication
  alias ServiceRadarNVR.PublicationRecovery
  alias ServiceRadarNVR.Reads
  alias ServiceRadarNVR.Session
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage

  @doc """
  Provision a new empty private root with authenticated Core preparation bytes.

  This offline operation requires exclusive provider attachment and retired
  writers. `reference` contains trusted `:storage_id`, `:binding_id` and
  `:binding_sha256`. Exact retries sync unchanged evidence; existing spools and
  partial/conflicting files are preserved and refused. Success is local
  installation only: admission remains closed pending two-sided completion.
  """
  def bootstrap_storage(root, reference, preparation),
    do: ServiceRadarNVR.StorageBootstrap.initialize(root, reference, preparation)

  @doc """
  Durably retain Core's authenticated installation acknowledgement offline.

  Requires the original installed preparation, matching storage/binding reference,
  exclusive provider attachment and retired writers. The preparation and marker
  are synced before the acknowledgement; exact retries preserve existing bytes.
  Partial, conflicting or unsafe evidence is refused without replacement. This
  records historical installation evidence and leaves admission closed.
  """
  def acknowledge_bootstrap(root, reference, bytes),
    do: ServiceRadarNVR.StorageBootstrap.acknowledge(root, reference, bytes)

  @doc """
  Inspect an exclusively attached bootstrap root without changing or syncing it.

  Returns the canonical preparation and optional acknowledgement, their digests,
  operation/storage IDs, and retained control bytes including the storage marker.
  An absent acknowledgement reserves 512 future control bytes. Unexpected entries
  and incomplete, conflicting or unsafe evidence are refused and preserved.
  This bounded offline observation is neither a reservation nor current Core
  history proof; retry the original write to confirm durability before delivery.
  """
  def bootstrap_evidence(root, reference), do: ServiceRadarNVR.StorageBootstrap.inspect(root, reference)

  def start_recording(identity, clock) do
    case DynamicSupervisor.start_child(ServiceRadarNVR.Sessions, {Session, {self(), identity, clock}}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :inbox)}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :recording_unavailable}
  end

  def status(pid, timeout \\ 5000), do: GenServer.call(pid, :status, timeout)
  def stop(pid), do: GenServer.call(pid, :stop)

  @doc "Read-only local capacity observation, not a reservation or pool capability."
  def capacity, do: ServiceRadarNVR.Capacity.status()

  @doc "List retained block IDs, including incomplete blocks, from a volume scan; not a coverage catalog."
  def list_blocks, do: Reads.run(&inspect_inventory/0)

  @doc """
  Report the local state of each block in `block_ids` (at most 50), in order.

  Each entry has `:block_id`, `:state` (`:sealed`, `:incomplete`, `:unresolved`
  or `:absent`), `:writing` (an admitted writer holds it now), `:bytes` (charged
  on disk, nil when absent or unmeasurable), `:descriptor_sha256` (sealed only)
  and `:reason` (unresolved only, an error class). State comes from the block's
  journal and file lengths without reading media (`Spool.journal_state/3`):
  `:sealed` means its journal holds a seal record. Fetch the descriptor or read
  the media to verify the bytes. `:absent` means no directory exists, which is
  not proof the block never existed. Runs in the shared read pool; nothing on
  disk changes.
  """
  def block_states(block_ids) when is_list(block_ids) and length(block_ids) in 1..50 do
    if Enum.all?(block_ids, &Blocks.valid_id?/1) and length(Enum.uniq(block_ids)) == length(block_ids),
      do: Reads.run(fn -> inspect_states(block_ids) end),
      else: {:error, :invalid_block_id}
  end

  def block_states(_block_ids), do: {:error, :invalid_block_id}

  @doc """
  One page of the block ledger: up to `limit` (1..100) blocks after `after_id`
  (nil from the start), ascending by ID, each reported as in `block_states/1`.
  `{:error, :nvr_inventory_rebuilding}` while the ledger is being built.
  """
  def block_page(after_id, limit) when limit in 1..100 and (is_nil(after_id) or is_binary(after_id)) do
    if is_nil(after_id) or Blocks.valid_id?(after_id),
      do: Reads.run(fn -> inspect_page(after_id, limit) end),
      else: {:error, :invalid_block_id}
  end

  def block_page(_after_id, _limit), do: {:error, :invalid_block_page}

  defp inspect_page(after_id, limit) do
    with {:ok, ids} <- ServiceRadarNVR.Capacity.ledger_page(after_id, limit) do
      inspect_states(ids)
    end
  end

  defp inspect_states(block_ids) do
    with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage(),
         writing = ServiceRadarNVR.Capacity.active_blocks(),
         tombstones = ServiceRadarNVR.Capacity.tombstoned_blocks(block_ids),
         states =
           Enum.map(block_ids, fn id ->
             Blocks.state(storage, id, limits, MapSet.member?(writing, id), MapSet.member?(tombstones, id))
           end),
         :ok <- Storage.verify(storage) do
      {:ok, states}
    end
  end

  defp inspect_inventory do
    with {:ok, storage, _limits} <- ServiceRadarNVR.Capacity.recovery_storage(),
         {:ok, inventory} <- ServiceRadarNVR.Disk.inventory(storage) do
      {:ok, Enum.sort(inventory.block_ids)}
    end
  end

  @doc """
  Verify a sealed block without changing disk or requiring a saved notification.

  Includes `init_format` derived from the verified initialization bytes. This is
  local media evidence, not a publication receipt or playback authorization.
  """
  def sealed_block(block_id), do: Reads.run(fn -> inspect_block(block_id) end)

  defp inspect_block(block_id) do
    with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage() do
      Blocks.inspect(storage, block_id, limits)
    end
  end

  @doc """
  Return canonical v1 descriptor JSON for a verified sealed local block.

  This trusted same-VM API uses the same verification as `sealed_block/1`. The
  portable bytes contain no local paths or storage receipts and grant neither
  publication authority nor playback access. Inspection does not mutate disk.
  """
  def block_descriptor(block_id) do
    if Blocks.valid_id?(block_id) do
      Reads.run(fn -> read_descriptor(block_id) end)
    else
      {:error, :invalid_block_id}
    end
  end

  defp read_descriptor(block_id) do
    with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage() do
      Blocks.descriptor(storage, block_id, limits)
    end
  end

  @doc """
  Read verified initialization bytes or one fragment bound to a descriptor digest.

  `descriptor_sha256` is the lowercase hexadecimal SHA-256 of `block_descriptor/1`
  JSON. Select `:init` or `{:fragment, sequence}`; paths and arbitrary ranges are
  not accepted. Each call verifies the entire sealed block before comparing the
  descriptor digest, then rechecks the selected bytes. The runtime bounds output
  to 1 MiB for initialization or 4 MiB for a fragment.

  This trusted same-VM API shares four read slots and a ten-second admitted-task
  deadline with discovery and inspection. It supplies neither playback
  authorization nor remote transport or downstream buffering budgets.
  """
  def read_block(block_id, descriptor_sha256, selector),
    do: read_selected_block(block_id, descriptor_sha256, selector, ServiceRadarNVR.ReadTasks)

  @doc """
  `read_block/3` for the playback read listener, in its own read pool.

  The pool has `SERVICERADAR_NVR_PLAYBACK_READ_SLOTS` slots (default 8) and the
  same ten-second admitted-task deadline, so playback cannot take the four slots
  that discovery, inspection, archive and descriptor reads share.
  """
  def playback_read(block_id, descriptor_sha256, selector),
    do: read_selected_block(block_id, descriptor_sha256, selector, ServiceRadarNVR.PlaybackReadTasks)

  defp read_selected_block(block_id, descriptor_sha256, :init, pool) do
    read_verified(block_id, descriptor_sha256, &Spool.read_init/1, pool)
  end

  defp read_selected_block(block_id, descriptor_sha256, {:fragment, sequence}, pool)
       when is_integer(sequence) and sequence >= 0 do
    read_verified(block_id, descriptor_sha256, &Spool.read_fragment(&1, sequence), pool)
  end

  defp read_selected_block(_block_id, _descriptor_sha256, _selector, _pool), do: {:error, :invalid_media_selector}

  @doc """
  Persist one immutable local publication intent without blocking recording workers.

  The reference contains canonical UUIDs `:operation_id` and `:recording_block_id`
  plus `:descriptor_sha256` from Core's frozen descriptor. The trusted caller
  must establish that original authority first; these identifiers are correlation,
  not locally verifiable authority or catalog acknowledgement. Exact retries sync
  the same record, while conflicts and incomplete files remain untouched.
  One supervised publication task runs at a time with a thirty-second deadline,
  including after caller loss. Saturation returns `:nvr_publication_capacity`.
  A timeout is an unknown outcome: inspect or retry the same operation.
  """
  def prepare_publication(block_id, reference), do: ServiceRadarNVR.Capacity.prepare_publication(block_id, reference)

  @doc "Observe automatic publication progress; unavailable when disabled or restarting."
  def publication_delivery_status, do: ServiceRadarNVR.PublicationScheduler.status()

  @doc "Deliver one retained intent to the installed Core receiver and persist its acknowledgement."
  def deliver_publication(block_id), do: ServiceRadarNVR.Delivery.run(block_id)

  @doc "Read and reverify a retained intent; does not publish, acknowledge or authorize playback."
  def publication_intent(block_id) do
    Reads.run(fn ->
      with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage() do
        Publication.inspect(storage, block_id, :intent, limits)
      end
    end)
  end

  @doc """
  Retain a trusted Core intent acknowledgement while local writers may be active.

  The canonical response must bind the exact verified local intent. The intent
  is synced before the acknowledgement; retries sync the same bytes. Both files
  remain for recovery. A timeout is an unknown outcome. This API validates
  correlation, not Core identity, and grants no availability or deletion rights.
  """
  def acknowledge_publication(block_id, bytes), do: ServiceRadarNVR.Capacity.acknowledge_publication(block_id, bytes)

  @doc "Read a retained acknowledgement after reverifying its intent and media; does not sync it."
  def publication_acknowledgement(block_id) do
    Reads.run(fn ->
      with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage() do
        Publication.inspect(storage, block_id, :acknowledgement, limits)
      end
    end)
  end

  @doc """
  Read a bounded page of retained publication evidence after restart.

  Start with a nil cursor, then pass the returned `next_cursor` unchanged until
  it is nil. The cursor binds the storage UUID and last block ID. The default
  page contains one entry; the limit must be 1..16. Pages share the four read
  slots and ten-second task deadline. A timeout returns no page; retry the same
  cursor with a smaller limit. The scan covers every block directory on the
  volume.

  `:pending` includes a verified intent for exact redelivery. `:intent_accepted`
  includes that intent and its matching retained acknowledgement. `:unprepared`
  means neither record was observed, not that the block is sealed or publishable.
  `:unresolved` includes the verification error, without delivery bytes. Unsafe
  inventory fails the whole page. No operation writes, repairs or syncs files.
  Confirm a recovered record's durable boundary by retrying its original write
  operation with the same reference or acknowledgement bytes before delivery.

  Pages are observations, not a snapshot or delivery queue. Concurrent publication
  may change an earlier entry; new blocks before the cursor appear on the next
  scan from nil. Retain unresolved work and rescan; cursor progress acknowledges
  nothing. These trusted same-VM records prove correlation, not authenticated
  Core origin, catalog availability, playback permission or deletion authority.
  """
  def publication_page(cursor \\ nil, limit \\ 1), do: Reads.run(fn -> PublicationRecovery.page(cursor, limit) end)

  @doc """
  Recover and seal one retained block using its expected identity (including clock).

  Refuses while any local recording or publication operation is active. The provisioned volume
  must already have exclusive attachment and the previous writer must be retired;
  this local guard does not fence another replica. No capture or publication starts.
  Includes `init_format` as in `sealed_block/1`. Format decoding follows repair
  and sealing; a format error does not mean the files were left unchanged.
  A closed recovery gate observed after that work returns `{:error, :nvr_recovery_closed}`;
  any repair or seal already written remains.
  """
  def recover_block(block_id, expected_identity) do
    with {:ok, snapshot} <- ServiceRadarNVR.Capacity.recover_block(block_id, expected_identity),
         result = Blocks.with_format(snapshot),
         :ok <- ServiceRadarNVR.Capacity.recovery_ready(),
         do: result
  end

  defp read_verified(block_id, expected_digest, read, pool)
       when is_binary(expected_digest) and byte_size(expected_digest) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_digest) do
      Reads.run(fn -> read_selected(block_id, expected_digest, read) end, pool)
    else
      {:error, :invalid_descriptor_digest}
    end
  end

  defp read_verified(_block_id, _expected_digest, _read, _pool), do: {:error, :invalid_descriptor_digest}

  defp read_selected(block_id, expected_digest, read) do
    with {:ok, snapshot} <- inspect_block(block_id),
         {:ok, descriptor} <- Blocks.descriptor(snapshot),
         digest = Base.encode16(:crypto.hash(:sha256, descriptor), case: :lower),
         true <- digest == expected_digest || {:error, :descriptor_digest_mismatch} do
      read.(snapshot)
    end
  end
end
