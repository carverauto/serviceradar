defmodule ServiceRadarCoreElx.CameraRecording.Storage do
  @moduledoc """
  Binds a private POSIX spool root to its provisioned storage-lifetime UUID.

  Infrastructure calls `initialize/2` explicitly, before starting recording, on
  an existing empty private root. It exclusively creates `.storage-id` containing
  the canonical UUID and one newline, then syncs the file and directory. Exact
  retries verify and sync without rewriting. Incomplete or conflicting markers
  are preserved for operator reconciliation, never repaired by a recorder.

  `open/2` is read-only. Its handle pins the root and marker device/inode for the
  subsequent local operations; `verify/1` also rechecks permissions and bytes.
  A restart opens a new handle against the same configured UUID. This detects
  missing/misbound storage and observed replacement, not physical-volume identity
  or malicious changes by a privileged host. Provisioning owns that association.
  """

  @marker ".storage-id"
  @marker_bytes 37
  @enforce_keys [:root, :id, :root_identity, :marker_identity]
  defstruct @enforce_keys

  @doc "Provision once; only an empty, already-private root can gain a new identity."
  def initialize(root, id) do
    root = Path.expand(root)

    with {:ok, id} <- storage_id(id),
         {:ok, _} <- private_stat(root, :directory) do
      case File.lstat(Path.join(root, @marker)) do
        {:error, :enoent} -> initialize_empty(root, id)
        {:ok, _} -> sync_existing(root, id)
        {:error, _} = error -> error
      end
    end
  end

  @doc "Verify an existing marker without initializing or changing anything."
  def open(root, id) do
    root = Path.expand(root)

    with {:ok, id} <- storage_id(id),
         {:ok, root_stat} <- private_stat(root, :directory),
         {:ok, marker_stat} <- private_stat(Path.join(root, @marker), :regular),
         :ok <- read_marker(root, id, marker_stat),
         :ok <- unchanged(root, :directory, root_stat),
         :ok <- unchanged(Path.join(root, @marker), :regular, marker_stat) do
      {:ok,
       %__MODULE__{
         root: root,
         id: id,
         root_identity: file_identity(root_stat),
         marker_identity: file_identity(marker_stat)
       }}
    end
  end

  @doc "Refuse writes or new receipts after an observed root/marker change."
  def verify(%__MODULE__{} = storage) do
    case open(storage.root, storage.id) do
      {:ok, ^storage} -> :ok
      {:ok, _} -> {:error, :storage_changed}
      {:error, _} = error -> error
    end
  end

  defp initialize_empty(root, id) do
    with {:ok, []} <- File.ls(root),
         :ok <- create_marker(root, id) do
      sync_existing(root, id)
    else
      {:ok, _entries} -> {:error, :storage_not_empty}
      {:error, :eexist} -> sync_existing(root, id)
      {:error, _} = error -> error
    end
  end

  defp create_marker(root, id) do
    with_file(Path.join(root, @marker), [:write, :exclusive], fn device ->
      with :ok <- File.chmod(Path.join(root, @marker), 0o600),
           :ok <- :file.write(device, id <> "\n") do
        :file.sync(device)
      end
    end)
  end

  defp sync_existing(root, id) do
    with {:ok, storage} <- open(root, id),
         :ok <- with_file(Path.join(root, @marker), [:read, :write], &:file.sync/1),
         :ok <- with_file(root, [:read, :directory], &:file.sync/1),
         :ok <- verify(storage) do
      {:ok, storage}
    end
  end

  defp storage_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :recording_storage_identity_required}
    end
  end

  defp private_stat(path, type) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type, mode: mode} = stat} ->
        if Bitwise.band(mode, 0o077) == 0, do: {:ok, stat}, else: private_error(type)

      {:ok, _} ->
        {:error, if(type == :directory, do: :invalid_root, else: :invalid_storage_marker)}

      {:error, :enoent} when type == :regular ->
        {:error, :storage_identity_missing}

      {:error, _} = error ->
        error
    end
  end

  defp private_error(:directory), do: {:error, :root_not_private}
  defp private_error(:regular), do: {:error, :storage_marker_not_private}

  defp read_marker(root, id, %{size: @marker_bytes} = stat) do
    with_file(Path.join(root, @marker), [:read], fn device ->
      with {:ok, info} <- :file.read_file_info(device),
           true <- file_identity(File.Stat.from_record(info)) == file_identity(stat) || {:error, :storage_changed},
           {:ok, bytes} <- :file.read(device, @marker_bytes + 1) do
        check_marker(bytes, id)
      else
        :eof -> {:error, :invalid_storage_marker}
        {:error, _} = error -> error
      end
    end)
  end

  defp read_marker(_root, _id, _stat), do: {:error, :invalid_storage_marker}

  defp check_marker(<<uuid::binary-size(36), "\n">>, id) do
    case Ecto.UUID.cast(uuid) do
      {:ok, ^uuid} when uuid == id -> :ok
      {:ok, ^uuid} -> {:error, :storage_identity_mismatch}
      _ -> {:error, :invalid_storage_marker}
    end
  end

  defp check_marker(_bytes, _id), do: {:error, :invalid_storage_marker}

  defp unchanged(path, type, before) do
    with {:ok, after_stat} <- private_stat(path, type),
         true <- file_identity(before) == file_identity(after_stat) || {:error, :storage_changed} do
      :ok
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

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
