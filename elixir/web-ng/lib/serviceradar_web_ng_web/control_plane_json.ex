defmodule ServiceRadarWebNGWeb.ControlPlaneJSON do
  @moduledoc """
  Bounded private-control documents, decoded before the general JSON parser.

  Duplicate object keys and arrays are rejected so these object-only contracts
  retain one unambiguous interpretation of every submitted field.
  """

  import Plug.Conn

  alias ServiceRadar.JSONDocument

  def read(conn, limit) do
    with true <- json_content_type?(conn),
         {:ok, body, conn} when byte_size(body) <= limit <-
           read_body(conn, length: limit, read_length: limit, read_timeout: 5_000) do
      case JSONDocument.decode_object(body, limit) do
        {:ok, document} -> {:ok, document, conn}
        {:error, :invalid_request} -> {:error, 400, :invalid_request, conn}
      end
    else
      false -> {:error, 415, :unsupported_media_type, conn}
      {:more, _body, conn} -> {:error, 413, :request_too_large, conn}
      {:ok, body, conn} when is_binary(body) -> {:error, 413, :request_too_large, conn}
      _ -> {:error, 400, :invalid_request, conn}
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() == "application/json"

      _ ->
        false
    end
  end
end
