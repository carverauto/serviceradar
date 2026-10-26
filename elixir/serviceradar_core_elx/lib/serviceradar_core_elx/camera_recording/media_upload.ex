defmodule ServiceRadarCoreElx.CameraRecording.MediaUpload do
  @moduledoc """
  Explicitly uploads one frozen block through the private isolated storage service.

  The caller supplies only a block UUID. Installed infrastructure configuration
  supplies the binding, local root and private HTTPS credentials; provider keys
  never enter this process. There is no scheduler or automatic retry. Completion
  releases the upload lease, preserves every spool file and reports no archive
  availability. A retained dispatch, including an unknown one, is never rearmed.

  The Storage handle detects observed root/marker replacement. Regular-file and
  directory checks reject static aliases; they are not an attestation against a
  privileged host changing the filesystem concurrently. The isolated receiver
  hashes the exact staged bytes against the frozen intent before obtaining a
  provider grant, and independently verifies the remote bytes afterward.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.JSONDocument
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.CameraStorage.Config
  alias ServiceRadarCoreElx.CameraStorage.HTTP

  @maximum 16_777_216
  @operation_ms 30_000

  def upload_once(block_id) do
    deadline = now() + @operation_ms
    opts = [actor: SystemActor.system(:camera_archive_storage)]

    with {:ok, ^block_id} <- Ecto.UUID.cast(block_id),
         {:ok, config} <- Config.load_recorder(System.get_env("VMS_MEDIA_UPLOAD_CONFIG")),
         {:ok, storage} <-
           Storage.open(config.root, Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)),
         {:ok, %RecordingBlock{} = block} <- Ash.get(RecordingBlock, block_id, opts),
         {:ok, path, length} <- local_media(storage, block),
         {:ok, %ArchiveBinding{} = binding} <- Ash.get(ArchiveBinding, config.binding_id, opts),
         {:ok, lease} <- RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), @operation_ms, opts) do
      try do
        with {:ok, _} <- RecordingBlocks.bind_archive(lease, binding.id, binding.destination_sha256, opts),
             :ok <- Storage.verify(storage),
             {:ok, ^path, ^length} <- local_media(storage, block),
             {:ok, result} <- transfer(config.client, path, length, lease, deadline),
             :ok <- Storage.verify(storage) do
          {:ok, result}
        end
      after
        RecordingBlocks.release_upload(lease, opts)
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :media_upload_unavailable}
    end
  end

  defp local_media(storage, %{storage_id: id, block_key: key, descriptor: %{"media" => %{"length" => length}}})
       when id == storage.id and is_binary(key) and is_integer(length) and length in 1..@maximum do
    directory = Path.join(storage.root, key)
    path = Path.join(directory, "media.m4s")

    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, key),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, %File.Stat{type: :regular, links: 1, size: ^length}} <- File.lstat(path),
         :ok <- Storage.verify(storage) do
      {:ok, path, length}
    else
      _ -> {:error, :local_media_unavailable}
    end
  end

  defp local_media(_, _), do: {:error, :local_media_unavailable}

  defp transfer(client, path, length, lease, deadline) do
    wire_lease = %{
      "id" => lease.id,
      "upload_token" => lease.upload_token,
      "upload_epoch" => Integer.to_string(lease.upload_epoch),
      "descriptor_sha256" => lease.descriptor_sha256
    }

    headers = [
      {"authorization", "Bearer " <> client.token},
      {"content-type", "application/octet-stream"},
      {"content-length", Integer.to_string(length)},
      {"x-serviceradar-upload-lease", Jason.encode!(wire_lease)}
    ]

    with remaining when remaining > 0 <- deadline - now(),
         {:ok, %{status: 200, body: bytes}} <-
           HTTP.request(
             client,
             :post,
             client.base_url <> "/v1/media-uploads",
             headers,
             {:file, path, length},
             remaining,
             4096
           ),
         {:ok,
          %{
            "schema_version" => 1,
            "status" => "media_verified",
            "dispatch_id" => id,
            "recording_readiness" => "unavailable",
            "archive_readiness" => "unavailable"
          } = result} <-
           JSONDocument.decode_object(bytes, 4096),
         true <- map_size(result) == 5,
         {:ok, ^id} <- Ecto.UUID.cast(id) do
      {:ok, result}
    else
      _ -> {:error, :media_upload_unavailable}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
