defmodule ServiceRadarCoreElx.CameraRecording.SpoolInitializer do
  @moduledoc """
  Explicit, offline provisioning of the recordings subdirectory on one volume.

  Invoke through release eval with the packaged camera-spool-init.config, no
  distribution and no service credentials. Infrastructure must first verify the
  volume association and exclusive mount. This command does not attest either,
  enable capture, repair retained storage or start the core application.
  """

  alias ServiceRadar.Camera.RecordingStorageIdentity
  alias ServiceRadarCoreElx.CameraRecording.Storage

  def main do
    Logger.configure(level: :none)

    result =
      with :ok <- isolated_runtime(),
           {:ok, id} <- expected_identity(),
           {:ok, volume} <- volume_root(System.get_env("VMS_SPOOL_VOLUME_ROOT")),
           root = Path.join(volume, "recordings"),
           :ok <- prepare_root(root),
           {:ok, _storage} <- Storage.initialize(root, id),
           :ok <- sync_directory(volume) do
        %{status: :initialized}
      else
        {:error, reason} when is_atom(reason) -> %{status: :refused, reason: reason}
      end

    finish(result)
  rescue
    _ -> finish(%{status: :refused, reason: :initialization_failed})
  end

  defp expected_identity do
    id =
      RecordingStorageIdentity.resolve!(
        System.get_env("SERVICERADAR_CAMERA_RECORDING_STORAGE_ID"),
        System.get_env("SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE"),
        System.get_env("SERVICERADAR_CAMERA_RECORDING_MEMBER")
      )

    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :recording_storage_identity_required}
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_configuration}
  end

  defp isolated_runtime do
    started = Application.started_applications()

    if Node.alive?() or Enum.any?(started, fn {app, _, _} -> app in [:serviceradar_core, :serviceradar_core_elx] end) do
      {:error, :isolated_runtime_required}
    else
      :ok
    end
  end

  defp volume_root(path) when is_binary(path) and byte_size(path) in 2..4096 do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :invalid_volume_root}
    end
  end

  defp volume_root(_), do: {:error, :invalid_volume_root}

  defp prepare_root(root) do
    case File.mkdir(root) do
      :ok -> File.chmod(root, 0o700)
      {:error, :eexist} -> :ok
      {:error, _} = error -> error
    end
  end

  defp sync_directory(path) do
    with {:ok, result} <- File.open(path, [:read, :raw, :directory], &:file.sync/1), do: result
  end

  defp finish(result) do
    IO.puts(Jason.encode!(result))
    System.halt(if(result.status == :initialized, do: 0, else: 1))
  end
end
