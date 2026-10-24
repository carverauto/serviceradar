defmodule ServiceRadarWebNGWeb.ControlPlaneJSON do
  @moduledoc """
  Bounded private-control documents, decoded before the general JSON parser.

  Duplicate object keys and arrays are rejected so these object-only contracts
  retain one unambiguous interpretation of every submitted field.
  """

  import Plug.Conn

  def read(conn, limit) do
    with true <- json_content_type?(conn),
         {:ok, body, conn} when byte_size(body) <= limit <-
           read_body(conn, length: limit, read_length: limit, read_timeout: 5_000) do
      case decode(body) do
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

  defp decode(body) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = decoded} -> plain_value(decoded)
      _ -> {:error, :invalid_request}
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

  defp plain_value(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      with false <- Map.has_key?(map, key),
           {:ok, value} <- plain_value(value) do
        {:cont, {:ok, Map.put(map, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp plain_value(value) when is_list(value), do: {:error, :invalid_request}
  defp plain_value(value), do: {:ok, value}
end
