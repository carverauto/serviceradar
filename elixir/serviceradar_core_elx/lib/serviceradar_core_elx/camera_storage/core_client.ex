defmodule ServiceRadarCoreElx.CameraStorage.CoreClient do
  @moduledoc false

  alias ServiceRadar.JSONDocument
  alias ServiceRadarCoreElx.CameraStorage.HTTP

  @paths %{
    challenge: "/v1/init-authorities/challenge",
    prepare: "/v1/init-uploads/prepare",
    grant: "/v1/init-uploads/grant",
    observe: "/v1/init-uploads/observe",
    verify: "/v1/init-uploads/verify"
  }

  def request(config, operation, document, timeout) when is_integer(timeout) and timeout > 0 do
    body = Jason.encode!(document)

    headers = [
      {"authorization", "Bearer " <> config.token},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    with {:ok, %{status: 200, body: bytes}} <-
           HTTP.request(
             config,
             :post,
             config.base_url <> path(Map.get(config, :kind, :init), operation),
             headers,
             body,
             timeout,
             16_384
           ),
         {:ok, result} <- JSONDocument.decode_object(bytes, 16_384) do
      {:ok, result}
    else
      _ -> {:error, :storage_authorization_unavailable}
    end
  end

  def request(_, _, _, _), do: {:error, :storage_deadline_expired}

  defp path(:init, operation), do: Map.fetch!(@paths, operation)
  defp path(:media, operation), do: String.replace(Map.fetch!(@paths, operation), "/init-", "/media-")
end
