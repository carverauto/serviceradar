defmodule ServiceRadarNVR.StorageBootstrap do
  @moduledoc """
  Install Core's exact preparation on a new, exclusively attached private root.

  Provisioning must authenticate Core and bind the configured storage/binding
  reference before calling this offline operation. Parsing proves correlation,
  not origin or physical durability. The recorder must be stopped and previous
  writers fenced by the provider. No startup path calls this installer.

  The preparation is created and synced BEFORE the storage marker, so a crash
  cannot leave a newly usable legacy spool. Exact retries may finish a missing
  marker, but never replace partial/conflicting evidence or adopt an old spool.
  Both files and the root are synced before success. The preparation keeps NVR
  admission closed until a separate two-sided history completion exists.

  Acknowledgement persistence re-syncs the preparation and marker before retaining
  Core's exact correlated response. Read-only inspection returns bounded evidence
  and control-byte accounting; it never repairs, syncs or grants current history
  eligibility. Both operations are offline provisioning boundaries, not runtime
  admission paths. Retained media requires the separate reconciliation protocol.
  """

  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @preparation ".bootstrap-preparation.json"
  @acknowledgement ".bootstrap-acknowledgement.json"
  @marker ".storage-id"
  @max_bytes 512

  def initialize(root, reference, bytes) do
    with {:ok, preparation} <- validate(reference, bytes),
         storage_id = preparation.storage_id,
         root = Path.expand(root),
         {:ok, root_stat} <- private_stat(root, :directory),
         :ok <- prepare_root(root, bytes, preparation),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, root_stat),
         :ok <- retain(Path.join(root, @marker), storage_id <> "\n", 37),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, root_stat),
         {:ok, storage} <- Storage.open(root, storage_id) do
      {:ok, %{storage: storage, preparation_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}}
    end
  end

  def acknowledge(root, reference, bytes) do
    with {:ok, retained} <- load(root, reference),
         :ok <- validate_acknowledgement(bytes, retained.context),
         root = retained.storage.root,
         :ok <- sync_existing(Path.join(root, @preparation), retained.preparation, @max_bytes),
         :ok <- sync_existing(Path.join(root, @marker), retained.storage.id <> "\n", 37),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, retained.root_stat),
         :ok <- retain(Path.join(root, @acknowledgement), bytes, @max_bytes),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, retained.root_stat),
         :ok <- Storage.verify(retained.storage) do
      {:ok, evidence(%{retained | acknowledgement: bytes})}
    end
  end

  def inspect(root, reference) do
    with {:ok, retained} <- load(root, reference), do: {:ok, evidence(retained)}
  end

  defp load(root, reference) do
    root = Path.expand(root)

    with {:ok, root_stat} <- private_stat(root, :directory),
         {:ok, entries} <- File.ls(root),
         true <- bootstrap_entries?(entries) || {:error, :storage_bootstrap_requires_new_root},
         {:ok, bytes} <- read_existing(Path.join(root, @preparation), @max_bytes),
         {:ok, context} <- validate(reference, bytes),
         {:ok, marker} <- read_existing(Path.join(root, @marker), 37),
         true <- marker == context.storage_id <> "\n" || {:error, :storage_bootstrap_conflict},
         {:ok, storage} <- Storage.open(root, context.storage_id),
         {:ok, acknowledgement} <- read_acknowledgement(root, entries, context),
         :ok <- unchanged_root(root, root_stat) do
      {:ok,
       %{
         storage: storage,
         root_stat: root_stat,
         context: context,
         preparation: bytes,
         acknowledgement: acknowledgement
       }}
    end
  end

  defp evidence(retained) do
    acknowledgement = retained.acknowledgement

    Map.merge(retained.context, %{
      state: if(is_nil(acknowledgement), do: :prepared, else: :installation_acknowledged),
      preparation: retained.preparation,
      acknowledgement: acknowledgement,
      acknowledgement_sha256: if(is_nil(acknowledgement), do: nil, else: digest(acknowledgement)),
      used_control_bytes: 37 + byte_size(retained.preparation) + byte_size(acknowledgement || ""),
      pending_control_bytes: if(is_nil(acknowledgement), do: @max_bytes, else: 0)
    })
  end

  defp validate_acknowledgement(bytes, preparation) when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes do
    expected = %{
      "version" => 1,
      "kind" => "local_storage_bootstrap_installed",
      "operation_id" => preparation.operation_id,
      "storage_id" => preparation.storage_id,
      "preparation_sha256" => preparation.preparation_sha256
    }

    case CanonicalJSON.encode(expected) do
      {:ok, ^bytes} -> :ok
      _ -> {:error, :invalid_storage_bootstrap_acknowledgement}
    end
  end

  defp validate_acknowledgement(_, _), do: {:error, :invalid_storage_bootstrap_acknowledgement}

  defp read_acknowledgement(root, entries, preparation) do
    if @acknowledgement in entries do
      with {:ok, bytes} <- read_existing(Path.join(root, @acknowledgement), @max_bytes),
           :ok <- validate_acknowledgement(bytes, preparation),
           do: {:ok, bytes}
    else
      {:ok, nil}
    end
  end

  defp validate(%{storage_id: storage_id, binding_id: binding_id, binding_sha256: digest} = reference, bytes)
       when map_size(reference) == 3 and is_binary(bytes) and byte_size(bytes) in 1..@max_bytes do
    with {:ok,
          %{
            "version" => 1,
            "kind" => "local_storage_bootstrap_prepared",
            "operation_id" => operation_id,
            "storage_id" => ^storage_id,
            "binding_id" => ^binding_id,
            "binding_sha256" => ^digest
          } = document}
         when map_size(document) == 6 <- Jason.decode(bytes),
         true <- Enum.all?([operation_id, storage_id, binding_id], &canonical_uuid?/1),
         true <- is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, ^bytes} <- CanonicalJSON.encode(document) do
      {:ok, %{storage_id: storage_id, operation_id: operation_id, preparation_sha256: digest(bytes)}}
    else
      _ -> {:error, :invalid_storage_bootstrap_preparation}
    end
  end

  defp validate(_, _), do: {:error, :invalid_storage_bootstrap_preparation}

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_), do: false

  defp prepare_root(root, bytes, preparation) do
    case File.ls(root) do
      {:ok, []} ->
        retain(Path.join(root, @preparation), bytes, @max_bytes)

      {:ok, entries} ->
        prepared? = @preparation in entries and bootstrap_entries?(entries)

        with true <- prepared? || {:error, :storage_bootstrap_requires_new_root},
             true <- (@acknowledgement not in entries or @marker in entries) || {:error, :storage_bootstrap_conflict},
             {:ok, _acknowledgement} <- read_acknowledgement(root, entries, preparation),
             do: sync_existing(Path.join(root, @preparation), bytes, @max_bytes)

      {:error, _} = error ->
        error
    end
  end

  defp bootstrap_entries?(entries), do: Enum.all?(entries, &(&1 in [@preparation, @marker, @acknowledgement]))
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp read_existing(path, limit) do
    with_existing(path, [:read], limit, &read_opened(&1, &2, limit))
  end

  defp with_existing(path, modes, limit, fun) do
    case private_stat(path, :regular) do
      {:ok, %{size: size} = stat} when size in 1..limit ->
        with_file(path, modes, &fun.(&1, stat))

      {:error, _} = error ->
        error

      _ ->
        {:error, :storage_bootstrap_conflict}
    end
  end

  # Storage.initialize/2 deliberately accepts only an empty root. Bootstrap must
  # instead retain its admission barrier first, then install the same public
  # 37-byte marker contract; Storage.open/2 verifies the resulting pair's identity.
  defp retain(path, bytes, limit) do
    result =
      with_file(path, [:write, :exclusive], fn device ->
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(device, bytes),
             do: :file.sync(device)
      end)

    case result do
      :ok -> :ok
      {:error, :eexist} -> sync_existing(path, bytes, limit)
      {:error, _} = error -> error
    end
  end

  defp sync_existing(path, expected, limit) do
    with_existing(path, [:read, :write], limit, &sync_opened(&1, &2, expected))
  end

  defp sync_opened(device, stat, expected) do
    case read_opened(device, stat, byte_size(expected)) do
      {:ok, ^expected} -> :file.sync(device)
      {:error, _} = error -> error
      _ -> {:error, :storage_bootstrap_conflict}
    end
  end

  defp read_opened(device, stat, limit) do
    with {:ok, info} <- :file.read_file_info(device),
         true <- file_identity(File.Stat.from_record(info)) == file_identity(stat),
         {:ok, bytes} <- :file.read(device, limit + 1),
         true <- byte_size(bytes) == stat.size and byte_size(bytes) <= limit do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :storage_bootstrap_conflict}
    end
  end

  defp private_stat(path, type) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type, mode: mode, links: links} = stat}
      when type == :directory or links == 1 ->
        if Bitwise.band(mode, 0o077) == 0, do: {:ok, stat}, else: {:error, :storage_bootstrap_not_private}

      {:ok, _} ->
        {:error, :invalid_storage_bootstrap_file}

      {:error, _} = error ->
        error
    end
  end

  defp unchanged_root(root, before) do
    with {:ok, after_stat} <- private_stat(root, :directory),
         true <- file_identity(before) == file_identity(after_stat) || {:error, :storage_changed},
         do: :ok
  end

  defp file_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
  defp sync_directory(root), do: with_file(root, [:read, :directory], &:file.sync/1)

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
