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

  @operation_ms 30_000

  def upload_once(block_id) do
    deadline = now() + @operation_ms
    opts = [actor: SystemActor.system(:camera_archive_storage)]

    with {:ok, ^block_id} <- Ecto.UUID.cast(block_id),
         {:ok, config} <- Config.load_recorder(System.get_env("VMS_MEDIA_UPLOAD_CONFIG")),
         {:ok, storage} <-
           Storage.open(config.root, Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)),
         {:ok, %RecordingBlock{} = block} <- Ash.get(RecordingBlock, block_id, opts),
         {:ok, path, length} <- Storage.sealed_object(storage, block, :media),
         {:ok, %ArchiveBinding{} = binding} <- Ash.get(ArchiveBinding, config.binding_id, opts),
         {:ok, lease} <- RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), @operation_ms, opts) do
      try do
        with {:ok, _} <- RecordingBlocks.bind_archive(lease, binding.id, binding.destination_sha256, opts),
             :ok <- Storage.verify(storage),
             {:ok, ^path, ^length} <- Storage.sealed_object(storage, block, :media),
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
