defmodule ServiceRadarCoreElx.CameraRecording.Spool do
  @moduledoc """
  A bounded, append-only local recording block and its committed byte map.

  The recorder serializes calls and owns the CNPG lease. This module does not
  acquire that lease: identity includes its epoch, so another owner never writes
  the same block. Recovery requires exclusive ownership of the local directory.
  A snapshot is an internal read capability, not a substitute for authorization.

  Each append syncs media before syncing a checksummed journal record. Only then
  does the returned snapshot advance its readable high-water mark. Initialization
  syncs files and both directory entries on a local POSIX filesystem; a filesystem
  that cannot sync directories is rejected. This is node-local durability, not
  replication or an archive acknowledgement. No rename is used as a commit marker.

  `create/4` does not replace a block directory that already exists. If this call
  created the directory and failed before a complete journal record, it removes
  that directory and only the files it may have written there, then syncs the
  parent so the removal survives a crash. A complete recoverable journal is kept
  when a later sync fails, and a complete corrupt journal is kept as evidence.
  When removal or that parent sync fails, `create/4` returns
  `{:error, {:create_cleanup_failed, reason, cleanup_reason}}`; a later `create/4`
  then sees the directory and returns `{:error, :eexist}`. A failed append may
  leave a tail: recover before writing again. Recovery rejects file aliases and verifies
  every committed fragment, discards only incomplete journal records and media
  beyond the committed high-water mark, and rejects complete corrupt records.
  Sealing journals the whole-block digest and permanently prevents further append.
  Fragment entries retain optional `tail_duration_source: :previous_sample`
  provenance as a JSON string when the packager inferred its final sample's duration.
  """

  alias ServiceRadarCoreElx.CameraRecording.Storage

  @identity_keys ~w(source_id profile recorder_epoch block_sequence)a
  @record_bytes 4096
  @defaults %{
    max_init_bytes: 1_048_576,
    max_fragment_bytes: 8_388_608,
    max_block_bytes: 67_108_864,
    max_fragments: 512,
    max_fragment_duration_ns: 10_000_000_000
  }
  @ceilings %{
    max_init_bytes: 1_048_576,
    max_fragment_bytes: 33_554_432,
    max_block_bytes: 536_870_912,
    max_fragments: 4096,
    max_fragment_duration_ns: 60_000_000_000
  }

  defstruct [
    :directory,
    :storage,
    :identity,
    :init,
    :limits,
    :hash,
    :sha256,
    entries: [],
    high_water: 0,
    journal_size: 0,
    sealed?: false
  ]

  @doc "Create a new block under a verified provisioned spool root."
  def create(%Storage{} = storage, identity, init, limits \\ %{}) do
    with :ok <- Storage.verify(storage),
         {:ok, limits} <- limits(limits),
         {:ok, identity} <- identity(identity),
         :ok <- check_binary(init, limits.max_init_bytes),
         {:ok, spool} <- create_block(storage, identity, init, limits),
         :ok <- Storage.verify(storage) do
      {:ok, spool}
    end
  end

  @doc "Commit one complete independently decodable fragment. Bounds never partially append."
  def append(%__MODULE__{sealed?: true}, _payload, _timing), do: {:error, :sealed}

  def append(%__MODULE__{} = spool, payload, timing) do
    with :ok <- Storage.verify(spool.storage),
         {:ok, entry} <- fragment_entry(spool, payload, timing),
         :ok <- append_record(spool, payload, entry),
         :ok <- Storage.verify(spool.storage) do
      updated = %{
        spool
        | entries: [entry | spool.entries],
          high_water: spool.high_water + byte_size(payload),
          journal_size: spool.journal_size + byte_size(encode_record(entry)),
          hash: :crypto.hash_update(spool.hash, payload)
      }

      {:ok, updated, entry}
    end
  end

  @doc "Seal a nonempty block; the snapshot contains its immutable media SHA-256."
  def seal(%__MODULE__{sealed?: true} = spool) do
    with :ok <- Storage.verify(spool.storage), do: {:ok, spool}
  end

  def seal(%__MODULE__{high_water: 0}), do: {:error, :empty_block}

  def seal(%__MODULE__{} = spool) do
    sha256 = spool.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    record = %{"type" => "seal", "sha256" => sha256}
    journal_size = spool.journal_size + byte_size(encode_record(record))

    with :ok <- Storage.verify(spool.storage),
         :ok <- append_record(spool, <<>>, record),
         :ok <- Storage.verify(spool.storage) do
      {:ok, %{spool | sealed?: true, sha256: sha256, journal_size: journal_size}}
    end
  end

  @doc "Snapshot complete fragments only; readers open their own descriptor."
  def snapshot(%__MODULE__{} = spool) do
    %{
      directory: spool.directory,
      storage: spool.storage,
      identity: spool.identity,
      init: spool.init,
      entries: Enum.reverse(spool.entries),
      high_water: spool.high_water,
      sealed?: spool.sealed?,
      sha256: spool.sha256
    }
  end

  @doc "Read a committed fragment by sequence, verifying its digest without the writer."
  def read_fragment(%{entries: entries, high_water: high_water, directory: directory, storage: storage}, sequence)
      when is_integer(sequence) and sequence >= 0 do
    case Enum.find(entries, &(&1["sequence"] == sequence)) do
      %{"offset" => offset, "length" => length, "sha256" => sha256}
      when offset + length <= high_water ->
        with :ok <- Storage.verify(storage), do: read_verified(Path.join(directory, "media.m4s"), offset, length, sha256)

      _ ->
        {:error, :not_readable}
    end
  end

  @doc "Read the immutable initialization segment from an internal snapshot."
  def read_init(%{directory: directory, storage: storage, init: %{"length" => length, "sha256" => sha256}}) do
    with :ok <- Storage.verify(storage), do: read_verified(Path.join(directory, "init.mp4"), 0, length, sha256)
  end

  @doc "Reconcile a block after writer exit. Identity must match the caller's expected block."
  def recover(%Storage{} = storage, directory, expected_identity, limits \\ %{}) do
    directory = Path.expand(directory)

    with :ok <- Storage.verify(storage),
         true <- Path.dirname(directory) == storage.root || {:error, :storage_directory_mismatch},
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         :ok <- recovery_files(directory),
         {:ok, limits} <- limits(limits),
         {:ok, expected_identity} <- identity(expected_identity),
         {:ok, journal} <-
           read_bounded(Path.join(directory, "journal"), (limits.max_fragments + 2) * (@record_bytes + 36)),
         {:ok, header, rest, header_size} <- read_record(journal),
         {:ok, init} <- check_header(header, expected_identity, limits),
         {:ok, _} <- read_verified(Path.join(directory, "init.mp4"), 0, init["length"], init["sha256"]),
         {:ok, spool} <-
           replay(rest, %__MODULE__{
             directory: directory,
             storage: storage,
             identity: expected_identity,
             init: init,
             limits: limits,
             journal_size: header_size,
             hash: :crypto.hash_init(:sha256)
           }),
         :ok <- Storage.verify(storage),
         :ok <- truncate_tail(Path.join(directory, "media.m4s"), spool.high_water),
         :ok <- Storage.verify(storage),
         :ok <- truncate_tail(Path.join(directory, "journal"), spool.journal_size),
         :ok <- Storage.verify(storage) do
      {:ok, spool}
    else
      :incomplete -> {:error, :incomplete_header}
      {:ok, %File.Stat{}} -> {:error, :invalid_block_directory}
      {:error, _} = error -> error
    end
  end

  defp recovery_files(directory) do
    Enum.reduce_while(~w(init.mp4 media.m4s journal), :ok, fn name, :ok ->
      case File.lstat(Path.join(directory, name)) do
        {:ok, %File.Stat{type: :regular, links: 1}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :invalid_block_file}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp fragment_entry(_spool, payload, _timing) when not is_binary(payload) or byte_size(payload) == 0,
    do: {:error, :invalid_fragment}

  defp fragment_entry(spool, payload, %{start_ns: start, duration_ns: duration} = timing)
       when is_integer(start) and start >= 0 and is_integer(duration) and duration > 0 and
              start + duration <= 9_223_372_036_854_775_807 do
    with {:ok, duration_source} <- tail_duration_source(timing),
         :ok <- check_capacity(spool, byte_size(payload), duration),
         true <- contiguous?(spool.entries, start) || {:error, :discontinuity} do
      {:ok,
       Map.merge(
         %{
           "type" => "fragment",
           "sequence" => length(spool.entries),
           "offset" => spool.high_water,
           "length" => byte_size(payload),
           "start_ns" => start,
           "duration_ns" => duration,
           "sha256" => digest(payload)
         },
         duration_source
       )}
    end
  end

  defp fragment_entry(_spool, _payload, _timing), do: {:error, :invalid_timing}

  defp tail_duration_source(timing) do
    case Map.fetch(timing, :tail_duration_source) do
      :error ->
        {:ok, %{}}

      {:ok, source} when source in [:previous_sample, "previous_sample"] ->
        {:ok, %{"tail_duration_source" => "previous_sample"}}

      {:ok, _source} ->
        {:error, :invalid_tail_duration_source}
    end
  end

  defp check_capacity(spool, size, duration) do
    cond do
      size > spool.limits.max_fragment_bytes ->
        {:error, :fragment_too_large}

      duration > spool.limits.max_fragment_duration_ns ->
        {:error, :fragment_too_long}

      spool.high_water + size > spool.limits.max_block_bytes ->
        {:error, :block_full}

      length(spool.entries) >= spool.limits.max_fragments ->
        {:error, :block_full}

      true ->
        :ok
    end
  end

  defp contiguous?([], _start), do: true
  defp contiguous?([last | _], start), do: last["start_ns"] + last["duration_ns"] == start

  defp append_record(spool, payload, record) do
    with_file(Path.join(spool.directory, "media.m4s"), [:read, :write], fn media ->
      with_file(Path.join(spool.directory, "journal"), [:read, :write], fn journal ->
        commit_record(media, journal, spool, payload, record)
      end)
    end)
  end

  defp commit_record(media, journal, spool, payload, record) do
    with :ok <- at_end(media, spool.high_water),
         :ok <- at_end(journal, spool.journal_size),
         :ok <- :file.write(media, payload),
         :ok <- :file.sync(media),
         :ok <- :file.write(journal, encode_record(record)) do
      :file.sync(journal)
    end
  end

  defp at_end(device, expected) do
    case :file.position(device, :eof) do
      {:ok, ^expected} -> :ok
      {:ok, _} -> {:error, :stale_spool}
      {:error, _} = error -> error
    end
  end

  defp replay(<<>>, spool), do: {:ok, spool}
  defp replay(_rest, %__MODULE__{sealed?: true}), do: {:error, :records_after_seal}

  defp replay(bytes, spool) do
    case read_record(bytes) do
      :incomplete ->
        {:ok, spool}

      {:error, _} = error ->
        error

      {:ok, record, rest, size} ->
        with {:ok, updated} <- replay_record(record, spool) do
          replay(rest, %{updated | journal_size: spool.journal_size + size})
        end
    end
  end

  defp replay_record(
         %{
           "type" => "fragment",
           "offset" => offset,
           "length" => length,
           "start_ns" => start,
           "duration_ns" => duration,
           "sha256" => sha256
         } = record,
         spool
       )
       when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 do
    timing =
      case Map.fetch(record, "tail_duration_source") do
        {:ok, source} -> %{start_ns: start, duration_ns: duration, tail_duration_source: source}
        :error -> %{start_ns: start, duration_ns: duration}
      end

    with true <- offset == spool.high_water || {:error, :invalid_offset},
         true <- length <= spool.limits.max_fragment_bytes || {:error, :fragment_too_large},
         {:ok, payload} <- read_verified(Path.join(spool.directory, "media.m4s"), offset, length, sha256),
         {:ok, ^record} <- fragment_entry(spool, payload, timing) do
      {:ok,
       %{
         spool
         | entries: [record | spool.entries],
           high_water: offset + length,
           hash: :crypto.hash_update(spool.hash, payload)
       }}
    else
      {:ok, _} -> {:error, :invalid_fragment_record}
      {:error, _} = error -> error
    end
  end

  defp replay_record(%{"type" => "seal", "sha256" => sha256}, %{high_water: high_water} = spool) when high_water > 0 do
    actual = spool.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    if actual == sha256,
      do: {:ok, %{spool | sealed?: true, sha256: sha256}},
      else: {:error, :block_digest_mismatch}
  end

  defp replay_record(_record, _spool), do: {:error, :invalid_record}

  defp encode_record(record) do
    payload = Jason.encode!(record)
    <<byte_size(payload)::unsigned-big-32, payload::binary, :crypto.hash(:sha256, payload)::binary>>
  end

  defp read_record(bytes) when byte_size(bytes) < 4, do: :incomplete

  defp read_record(<<size::unsigned-big-32, _rest::binary>>) when size > @record_bytes or size == 0,
    do: {:error, :invalid_record_size}

  defp read_record(<<size::unsigned-big-32, rest::binary>>) when byte_size(rest) < size + 32, do: :incomplete

  defp read_record(<<size::unsigned-big-32, rest::binary>>) do
    <<payload::binary-size(size), hash::binary-size(32), tail::binary>> = rest

    with true <- :crypto.hash(:sha256, payload) == hash || {:error, :journal_digest_mismatch},
         {:ok, record} when is_map(record) <- Jason.decode(payload) do
      {:ok, record, tail, size + 36}
    else
      _ -> {:error, :invalid_journal_record}
    end
  end

  defp check_header(
         %{
           "type" => "header",
           "version" => 1,
           "identity" => identity,
           "init" => %{"length" => length, "sha256" => sha256} = init
         },
         expected,
         limits
       )
       when identity == expected and is_integer(length) and length > 0 and is_binary(sha256) do
    if length <= limits.max_init_bytes and byte_size(sha256) == 64, do: {:ok, init}, else: {:error, :invalid_init}
  end

  defp check_header(_header, _expected, _limits), do: {:error, :identity_or_header_mismatch}

  defp identity(identity) when is_map(identity) do
    normalized =
      Map.new(@identity_keys, &{Atom.to_string(&1), Map.get(identity, &1, Map.get(identity, Atom.to_string(&1)))})

    with true <- valid_block_identity?(normalized),
         {:ok, clock} <- clock_metadata(Map.get(identity, :clock, Map.get(identity, "clock"))) do
      {:ok, Map.put(normalized, "clock", clock)}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp identity(_identity), do: {:error, :invalid_identity}

  defp valid_block_identity?(identity) do
    valid_identifier?(identity["source_id"]) and valid_identifier?(identity["profile"]) and
      unsigned_integer?(identity["block_sequence"]) and
      unsigned_integer?(identity["recorder_epoch"]) and identity["recorder_epoch"] > 0
  end

  # Packaging owns clock semantics. Persist its bounded context without inventing
  # a UTC mapping when the sender cannot provide one.
  defp clock_metadata(clock) when is_map(clock) do
    case Jason.encode(clock) do
      {:ok, bytes} when byte_size(bytes) <= 1024 -> Jason.decode(bytes)
      _ -> {:error, :invalid_clock}
    end
  end

  defp clock_metadata(_clock), do: {:error, :invalid_clock}

  defp valid_identifier?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and String.printable?(value)

  defp valid_identifier?(_value), do: false
  defp unsigned_integer?(value), do: is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807

  defp limits(overrides) when is_map(overrides) do
    merged = Map.merge(@defaults, overrides)

    if map_size(merged) == map_size(@defaults) and
         Enum.all?(@ceilings, fn {key, max} -> is_integer(merged[key]) and merged[key] in 1..max end),
       do: {:ok, merged},
       else: {:error, :invalid_limits}
  end

  defp limits(_limits), do: {:error, :invalid_limits}
  defp check_binary(bytes, max) when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= max, do: :ok
  defp check_binary(_bytes, _max), do: {:error, :invalid_init}
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp read_bounded(path, max) do
    with_file(path, [:read], fn device ->
      case :file.read(device, max + 1) do
        {:ok, bytes} when byte_size(bytes) <= max -> {:ok, bytes}
        {:ok, _} -> {:error, :journal_too_large}
        :eof -> {:error, :empty_journal}
        {:error, _} = error -> error
      end
    end)
  end

  defp read_verified(path, offset, length, sha256) do
    with_file(path, [:read], fn device ->
      with {:ok, bytes} when byte_size(bytes) == length <- :file.pread(device, offset, length),
           true <- digest(bytes) == sha256 do
        {:ok, bytes}
      else
        false -> {:error, :media_digest_mismatch}
        {:error, _} = error -> error
        _ -> {:error, :truncated_media}
      end
    end)
  end

  defp create_block(storage, identity, init, limits) do
    root = storage.root
    block_id = digest(Jason.encode!(Enum.map(@identity_keys, &identity[Atom.to_string(&1)])))
    directory = Path.join(root, block_id)
    init_meta = %{"length" => byte_size(init), "sha256" => digest(init)}
    header = %{"type" => "header", "version" => 1, "identity" => identity, "init" => init_meta}
    journal = encode_record(header)

    case File.mkdir(directory) do
      :ok -> finish_created_block(directory, storage, init, journal, identity, init_meta, limits)
      {:error, _} = error -> error
    end
  end

  defp finish_created_block(directory, storage, init, journal, identity, init_meta, limits) do
    case write_created_block(directory, storage.root, init, journal) do
      :ok ->
        {:ok,
         %__MODULE__{
           directory: directory,
           storage: storage,
           identity: identity,
           init: init_meta,
           limits: limits,
           hash: :crypto.hash_init(:sha256),
           journal_size: byte_size(journal)
         }}

      {:error, _} = error ->
        with :ok <- Storage.verify(storage), do: abandon_incomplete_create(storage.root, directory, error)
    end
  end

  defp write_created_block(directory, root, init, journal) do
    with :ok <- File.chmod(directory, 0o700),
         :ok <- write_new(Path.join(directory, "init.mp4"), init),
         :ok <- write_new(Path.join(directory, "media.m4s"), <<>>),
         :ok <- write_new(Path.join(directory, "journal"), journal),
         :ok <- sync_directory(directory) do
      sync_directory(root)
    end
  end

  defp abandon_incomplete_create(root, directory, {:error, reason} = error) do
    case creation_evidence(directory) do
      :incomplete -> remove_owned_incomplete_create(root, directory, reason, error)
      :preserve -> error
    end
  end

  defp remove_owned_incomplete_create(root, directory, reason, error) do
    case remove_created_directory(directory) do
      :ok -> sync_owned_removal(root, reason, error)
      {:error, cleanup} -> {:error, {:create_cleanup_failed, reason, cleanup}}
    end
  end

  defp sync_owned_removal(root, reason, error) do
    case sync_directory(root) do
      :ok -> error
      {:error, sync_reason} -> {:error, {:create_cleanup_failed, reason, sync_reason}}
    end
  end

  defp creation_evidence(directory) do
    case read_bounded(Path.join(directory, "journal"), @record_bytes + 36) do
      {:ok, bytes} ->
        case read_record(bytes) do
          :incomplete -> :incomplete
          _complete -> :preserve
        end

      {:error, reason} when reason in [:enoent, :empty_journal, :enametoolong] ->
        :incomplete

      {:error, _reason} ->
        :preserve
    end
  end

  defp remove_created_directory(directory) do
    with :ok <- remove_created_file(Path.join(directory, "init.mp4")),
         :ok <- remove_created_file(Path.join(directory, "media.m4s")),
         :ok <- remove_created_file(Path.join(directory, "journal")) do
      rmdir_created(directory)
    end
  end

  defp remove_created_file(path) do
    case File.lstat(path) do
      {:error, reason} when reason in [:enoent, :enametoolong] ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{}} ->
        {:error, :eexist}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rmdir_created(directory) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.rmdir(directory) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :eexist}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_new(path, bytes) do
    with_file(path, [:write, :exclusive], fn device ->
      with :ok <- File.chmod(path, 0o600), :ok <- :file.write(device, bytes), do: :file.sync(device)
    end)
  end

  defp truncate_tail(path, size) do
    with_file(path, [:read, :write], fn device ->
      with {:ok, actual} <- :file.position(device, :eof),
           true <- actual >= size || {:error, :truncated_media},
           {:ok, ^size} <- :file.position(device, size),
           :ok <- :file.truncate(device),
           do: :file.sync(device)
    end)
  end

  defp sync_directory(path), do: with_file(path, [:read, :directory], &:file.sync/1)

  defp with_file(path, modes, fun) do
    case :file.open(String.to_charlist(path), [:raw, :binary | modes]) do
      {:ok, device} ->
        try do
          fun.(device)
        after
          :file.close(device)
        end

      {:error, _} = error ->
        error
    end
  end
end
