defmodule ServiceRadarCoreElx.CameraRecording.ArchivePublication do
  @moduledoc """
  Completes one already-media-verified archive under a fresh bounded upload lease.

  Core derives the recovery manifest from immutable original proofs and owns the
  index transition. Only missing init or manifest objects enter the installed
  isolated storage service. Prepared or uncertain operations are never resent.
  Already-verified publication needs neither local storage nor installed provider
  configuration, including after recording stops. No scheduler, playback service
  or local reclamation is enabled by this command.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.JSONDocument
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.CameraStorage.Config
  alias ServiceRadarCoreElx.CameraStorage.HTTP

  @operation_ms 30_000

  def complete_once(block_id) do
    deadline = now() + @operation_ms
    opts = [actor: SystemActor.system(:camera_archive_storage)]

    with {:ok, ^block_id} <- Ecto.UUID.cast(block_id),
         {:ok, status} <- ArchiveUploads.publication_status(block_id, opts) do
      complete(status, block_id, deadline, opts)
    else
      :error -> {:error, :invalid_recording_block_id}
      {:ok, _} -> {:error, :invalid_recording_block_id}
      {:error, _} = error -> error
    end
  end

  defp complete(%{status: :available, result: result}, _, _, _), do: {:ok, result}
  defp complete(%{status: :media_required}, _, _, _), do: {:error, :media_verification_required}

  defp complete(%{status: :reconciliation_required}, _, _, _), do: {:error, :archive_reconciliation_required}

  defp complete(_status, block_id, deadline, opts) do
    with {:ok, remaining} <- remaining(deadline),
         {:ok, lease} <- RecordingBlocks.acquire_upload(block_id, Ecto.UUID.generate(), remaining, opts) do
      try do
        with {:ok, status} <- ArchiveUploads.publication_status(block_id, opts) do
          finish(status, lease, deadline, opts)
        end
      after
        RecordingBlocks.release_upload(lease, opts)
      end
    end
  end

  defp finish(%{status: :available, result: result}, _, _, _), do: {:ok, result}

  defp finish(%{status: :archive_verified}, lease, deadline, opts) do
    with {:ok, _} <- remaining(deadline), do: ArchiveUploads.publish_archive(lease, opts)
  end

  defp finish(%{status: phase, binding: binding}, lease, deadline, opts)
       when phase in [:init_required, :manifest_required] do
    with {:ok, _} <- remaining(deadline),
         {:ok, config} <- Config.load_recorder(System.get_env("VMS_MEDIA_UPLOAD_CONFIG")),
         true <- config.binding_id == binding.id || {:error, :archive_binding_mismatch},
         :ok <- ensure_init(phase, config, lease, deadline, opts),
         {:ok, _} <- remaining(deadline),
         {:ok, %{bytes: bytes}} <- ArchiveUploads.prepare_manifest(lease, opts),
         :ok <- transfer(config.client, :manifest, lease, bytes, deadline),
         {:ok, _} <- remaining(deadline) do
      ArchiveUploads.publish_archive(lease, opts)
    end
  end

  defp finish(%{status: :media_required}, _, _, _), do: {:error, :media_verification_required}
  defp finish(_, _, _, _), do: {:error, :archive_reconciliation_required}

  defp ensure_init(:manifest_required, _, _, _, _), do: :ok

  defp ensure_init(:init_required, config, lease, deadline, opts) do
    with {:ok, %RecordingBlock{} = block} <- Ash.get(RecordingBlock, lease.id, opts),
         {:ok, storage} <-
           Storage.open(config.root, Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)),
         {:ok, path, length} <- Storage.sealed_object(storage, block, :init),
         {:ok, bytes} <- read_init(path, length),
         :ok <- Storage.verify(storage),
         :ok <- transfer(config.client, :init, lease, bytes, deadline) do
      Storage.verify(storage)
    end
  end

  defp read_init(path, length) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case IO.binread(file, length + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) == length -> {:ok, bytes}
            _ -> {:error, :local_init_unavailable}
          end
        after
          File.close(file)
        end

      _ ->
        {:error, :local_init_unavailable}
    end
  end

  defp transfer(client, kind, lease, bytes, deadline) do
    {content_type, body, lease_headers} = body(kind, lease, bytes)

    headers =
      [
        {"authorization", "Bearer " <> client.token},
        {"content-type", content_type},
        {"content-length", Integer.to_string(byte_size(body))}
      ] ++ lease_headers

    expected_status = "#{kind}_verified"

    with {:ok, timeout} <- remaining(deadline),
         {:ok, %{status: 200, body: result}} <-
           HTTP.request(client, :post, client.base_url <> "/v1/#{kind}-uploads", headers, body, timeout, 4096),
         {:ok,
          %{
            "schema_version" => 1,
            "status" => ^expected_status,
            "dispatch_id" => id,
            "recording_readiness" => "unavailable",
            "archive_readiness" => "unavailable"
          } = receipt} <- JSONDocument.decode_object(result, 4096),
         true <- map_size(receipt) == 5,
         {:ok, ^id} <- Ecto.UUID.cast(id) do
      :ok
    else
      _ -> {:error, :archive_upload_unavailable}
    end
  end

  defp body(:init, lease, bytes) do
    document = %{"schema_version" => 1, "lease" => wire_lease(lease), "init_base64" => Base.encode64(bytes)}
    {"application/json", Jason.encode!(document), []}
  end

  defp body(:manifest, lease, bytes),
    do: {"application/octet-stream", bytes, [{"x-serviceradar-upload-lease", Jason.encode!(wire_lease(lease))}]}

  defp wire_lease(lease) do
    %{
      "id" => lease.id,
      "upload_token" => lease.upload_token,
      "upload_epoch" => Integer.to_string(lease.upload_epoch),
      "descriptor_sha256" => lease.descriptor_sha256
    }
  end

  defp remaining(deadline) do
    case deadline - now() do
      ms when ms > 0 -> {:ok, ms}
      _ -> {:error, :archive_publication_expired}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
