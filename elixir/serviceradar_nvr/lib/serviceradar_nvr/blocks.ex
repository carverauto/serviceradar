defmodule ServiceRadarNVR.Blocks do
  @moduledoc false

  alias ServiceRadarRecording.Initialization
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.Descriptor

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)

  def inspect(storage, block_id, limits) do
    with {:ok, snapshot} <- Spool.inspect_sealed(storage, block_id, limits), do: with_format(snapshot)
  end

  def descriptor(storage, block_id, limits) do
    case inspect(storage, block_id, limits) do
      {:ok, snapshot} -> descriptor(snapshot)
      {:error, :enoent} -> missing_descriptor_input(storage, block_id)
      {:error, _} = error -> error
    end
  end

  defp missing_descriptor_input(storage, block_id) do
    with :ok <- Storage.verify(storage) do
      case File.lstat(Path.join(storage.root, block_id)) do
        {:error, :enoent} -> {:error, :block_not_found}
        {:ok, _stat} -> {:error, :unsealed_block}
        {:error, _} = error -> error
      end
    end
  end

  # Local state of one block from its journal and file lengths (no media read).
  def state(storage, block_id, limits, writing?) do
    entry = %{block_id: block_id, writing: writing?, bytes: nil, descriptor_sha256: nil, reason: nil}

    case ServiceRadarNVR.Disk.block_usage(storage.root, block_id) do
      {:error, :enoent} -> Map.put(entry, :state, :absent)
      {:error, _} -> Map.merge(entry, %{state: :unresolved, reason: :invalid_block_files})
      {:ok, bytes, _pending} -> journal_state(storage, block_id, limits, %{entry | bytes: bytes})
    end
  end

  defp journal_state(storage, block_id, limits, entry) do
    with {:ok, snapshot} <- Spool.journal_state(storage, block_id, limits),
         {:ok, digest} <- sealed_digest(snapshot) do
      Map.merge(entry, %{state: if(snapshot.sealed?, do: :sealed, else: :incomplete), descriptor_sha256: digest})
    else
      {:error, reason} -> Map.merge(entry, %{state: :unresolved, reason: reason_class(reason)})
    end
  end

  defp sealed_digest(%{sealed?: false}), do: {:ok, nil}

  defp sealed_digest(snapshot) do
    with {:ok, snapshot} <- with_format(snapshot),
         {:ok, bytes} <- descriptor(snapshot),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :unreadable_block

  def descriptor(snapshot) do
    with {:ok, descriptor} <- Descriptor.from_snapshot(snapshot, snapshot.init_format),
         do: Descriptor.encode(descriptor)
  end

  # Why a sealed block read failed, for the routes that answer it:
  # `:block_not_found` when the ID names no retained block, `:block_not_sealed`
  # when the block is present but no seal verifies, `:read_unavailable` when the
  # read pool or recovery state refused the read, and `:other` for anything else.
  def read_error(reason, route \\ :archive)

  def read_error(:enoent, :archive), do: :block_not_found
  def read_error(reason, _route) when reason in [:block_not_found, :invalid_block_id], do: :block_not_found

  def read_error(reason, :descriptor)
      when reason in [
             :invalid_block_directory,
             :invalid_block_file,
             :invalid_journal_record,
             :invalid_record_size,
             :empty_journal,
             :journal_too_large,
             :incomplete_header,
             :identity_or_header_mismatch,
             :invalid_identity,
             :invalid_init,
             :invalid_initialization,
             :records_after_seal,
             :invalid_record,
             :invalid_offset,
             :fragment_too_large,
             :fragment_too_long,
             :block_full,
             :invalid_fragment_record,
             :invalid_timing,
             :invalid_tail_duration_source,
             :discontinuity,
             :invalid_recording_descriptor
           ], do: :block_not_sealed

  def read_error(reason, _route)
      when reason in [
             :nvr_read_capacity,
             :nvr_read_timeout,
             :nvr_read_unavailable,
             :nvr_recovery_closed,
             :nvr_storage_not_configured
           ], do: :read_unavailable

  def read_error(reason, _route)
      when reason in [
             :unsealed_block,
             :empty_block,
             :block_identity_mismatch,
             :uncommitted_block_bytes,
             :block_digest_mismatch,
             :journal_digest_mismatch,
             :media_digest_mismatch,
             :truncated_media
           ], do: :block_not_sealed

  def read_error(_reason, _route), do: :other

  def with_format(snapshot) do
    with {:ok, init} <- Spool.read_init(snapshot),
         {:ok, format} <- Initialization.parse(init) do
      {:ok, Map.put(snapshot, :init_format, format)}
    end
  end

  # Committed fragments are contiguous from offset zero, so in sequence order
  # they are exactly the sealed media file, bound here to its seal digest.
  def media(snapshot) do
    result =
      Enum.reduce_while(snapshot.entries, {:ok, []}, fn entry, {:ok, parts} ->
        case Spool.read_fragment(snapshot, entry["sequence"]) do
          {:ok, bytes} -> {:cont, {:ok, [parts | bytes]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, parts} <- result,
         media = IO.iodata_to_binary(parts),
         true <-
           (byte_size(media) == snapshot.high_water and
              Base.encode16(:crypto.hash(:sha256, media), case: :lower) == snapshot.sha256) ||
             {:error, :media_digest_mismatch} do
      {:ok, media}
    end
  end
end
