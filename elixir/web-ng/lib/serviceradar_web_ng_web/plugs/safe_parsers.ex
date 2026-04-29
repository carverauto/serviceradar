defmodule ServiceRadarWebNGWeb.Plugs.SafeParsers do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    if raw_field_survey_room_artifact?(conn) do
      conn
    else
      parse(conn, opts)
    end
  end

  defp parse(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    _err in [Plug.Parsers.ParseError] ->
      send_malformed_request(conn)
  end

  defp raw_field_survey_room_artifact?(%{method: "POST", request_path: request_path}) when is_binary(request_path) do
    String.starts_with?(request_path, "/v1/field-survey/") and
      String.ends_with?(request_path, "/room-artifacts")
  end

  defp raw_field_survey_room_artifact?(_conn), do: false

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
