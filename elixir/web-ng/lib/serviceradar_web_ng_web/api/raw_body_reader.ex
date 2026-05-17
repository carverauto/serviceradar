defmodule ServiceRadarWebNGWeb.Api.RawBodyReader do
  @moduledoc false

  @callback_prefix "/api/northbound/action-callbacks/"
  @raw_body_private_key :serviceradar_raw_body_chunks

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_store_raw_body(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_store_raw_body(conn, body)}
      other -> other
    end
  end

  def raw_body(conn) do
    conn.private
    |> Map.get(@raw_body_private_key, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp maybe_store_raw_body(%{request_path: request_path} = conn, body)
       when is_binary(request_path) and is_binary(body) do
    if String.starts_with?(request_path, @callback_prefix) do
      Plug.Conn.put_private(conn, @raw_body_private_key, [
        body | Map.get(conn.private, @raw_body_private_key, [])
      ])
    else
      conn
    end
  end

  defp maybe_store_raw_body(conn, _body), do: conn
end
