defmodule ServiceRadarWebNGWeb.Plugs.SafeParsers do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    try do
      Plug.Parsers.call(conn, opts)
    rescue
      _err in [Plug.Parsers.ParseError] ->
        send_malformed_request(conn)
    end
  end

  defp send_malformed_request(conn) do
    json = Phoenix.json_library()

    body =
      try do
        json.encode!(%{error: "malformed_request"})
      rescue
        _ -> "{\"error\":\"malformed_request\"}"
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(400, body)
    |> Plug.Conn.halt()
  end
end
