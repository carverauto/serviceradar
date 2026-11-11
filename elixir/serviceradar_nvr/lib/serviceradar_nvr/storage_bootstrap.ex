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
  """

  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @preparation ".bootstrap-preparation.json"
  @marker ".storage-id"
  @max_bytes 512

  def initialize(root, reference, bytes) do
    with {:ok, storage_id} <- validate(reference, bytes),
         root = Path.expand(root),
         {:ok, root_stat} <- private_stat(root, :directory),
         :ok <- prepare_root(root, bytes),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, root_stat),
         :ok <- retain(Path.join(root, @marker), storage_id <> "\n", 37),
         :ok <- sync_directory(root),
         :ok <- unchanged_root(root, root_stat),
         {:ok, storage} <- Storage.open(root, storage_id) do
      {:ok, %{storage: storage, preparation_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}}
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
      {:ok, storage_id}
    else
      _ -> {:error, :invalid_storage_bootstrap_preparation}
    end
  end

  defp validate(_, _), do: {:error, :invalid_storage_bootstrap_preparation}

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_), do: false

  defp prepare_root(root, bytes) do
    with {:ok, entries} <- File.ls(root) do
      cond do
        entries == [] ->
          retain(Path.join(root, @preparation), bytes, @max_bytes)

        @preparation in entries and Enum.all?(entries, &(&1 in [@preparation, @marker])) ->
          sync_existing(Path.join(root, @preparation), bytes, @max_bytes)

        true ->
          {:error, :storage_bootstrap_requires_new_root}
      end
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
    case private_stat(path, :regular) do
      {:ok, %{size: size} = stat} when size >= 1 and size <= limit ->
        with_file(path, [:read, :write], &sync_opened(&1, stat, expected))

      {:error, _} = error ->
        error

      _ ->
        {:error, :storage_bootstrap_conflict}
    end
  end

  defp sync_opened(device, stat, expected) do
    with {:ok, info} <- :file.read_file_info(device),
         true <- file_identity(File.Stat.from_record(info)) == file_identity(stat),
         {:ok, ^expected} <- :file.read(device, byte_size(expected) + 1),
         :ok <- :file.sync(device) do
      :ok
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
