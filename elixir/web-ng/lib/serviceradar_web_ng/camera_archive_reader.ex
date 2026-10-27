defmodule ServiceRadarWebNG.CameraArchiveReader do
  @moduledoc """
  Fetches one canonical archive range through the installed isolated reader.

  The caller owns current human authorization and proof checks before and after
  this exchange. Neither a browser nor a retained read plan selects a provider
  connection. Only private service credentials are installed in this process.
  """

  alias ServiceRadar.Camera.ArchiveStorageConfig
  alias ServiceRadar.Camera.ArchiveStorageHTTP

  def fetch(plan, deadline) do
    with {:ok, config} <- ArchiveStorageConfig.load_reader(System.get_env("VMS_ARCHIVE_READER_CONFIG")),
         true <- config.binding_id == plan["binding_id"],
         true <- config.destination_sha256 == plan["destination_sha256"],
         remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond),
         body = Jason.encode!(plan),
         headers = [
           {"authorization", "Bearer " <> config.client.token},
           {"content-type", "application/json"},
           {"content-length", Integer.to_string(byte_size(body))}
         ],
         length = plan["last"] - plan["first"] + 1,
         {:ok, %{status: 200, body: bytes}} <-
           ArchiveStorageHTTP.request(
             config.client,
             :post,
             config.client.base_url <> "/v1/archive-ranges",
             headers,
             body,
             remaining,
             length
           ),
         true <- byte_size(bytes) == length,
         true <- :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == plan["sha256"] do
      {:ok, bytes}
    else
      _ -> {:error, :archive_read_unavailable}
    end
  end
end
