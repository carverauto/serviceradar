defmodule ServiceRadarNVR.RecoveryGate do
  @moduledoc """
  Read-only deployment recovery gate, independent of the retained media volume.

  Deployment control supplies the boot-pinned generation and an atomically
  replaced state file. Kubernetes projected-volume symlinks are supported.
  Every check reads the current file; no ready result is cached. This is one
  admission prerequisite, not current-history completion or storage qualification.

  Closing this file does not retire an operation already in flight. The restore
  workflow must quiesce all authority-bearing processes before restoring data.
  NVR never creates, repairs or changes deployment recovery state.
  """

  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @max_bytes 256

  def load(env, root) do
    case {env["SERVICERADAR_NVR_RECOVERY_GENERATION"], env["SERVICERADAR_NVR_RECOVERY_STATE_FILE"]} do
      {nil, nil} ->
        {:ok, nil}

      {generation, path} when is_binary(generation) and is_binary(path) ->
        if Ecto.UUID.cast(generation) == {:ok, generation} and Path.type(path) == :absolute and
             outside_spool?(path, root),
           do: {:ok, %{generation: generation, path: Path.expand(path)}},
           else: {:error, :invalid_nvr_recovery_config}

      _ ->
        {:error, :invalid_nvr_recovery_config}
    end
  end

  def check(nil), do: {:error, :nvr_recovery_closed}

  def check(%{generation: generation, path: path}) do
    with {:ok, %{type: :regular, size: size}} when size in 1..@max_bytes <- File.stat(path),
         {:ok, expected} <- CanonicalJSON.encode(%{"generation" => generation, "state" => "ready"}),
         {:ok, ^expected} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      :ok
    else
      _ -> {:error, :nvr_recovery_closed}
    end
  end

  defp outside_spool?(_path, nil), do: true

  defp outside_spool?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path != root and not String.starts_with?(path, root <> "/")
  end
end
