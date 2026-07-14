defmodule ServiceRadarWebNGWeb.Plugs.SafeParsers do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      default: Plug.Parsers.init(opts),
      automation_callback: Plug.Parsers.init(Keyword.put(opts, :length, 4_096))
    }
  end

  @impl true
  def call(conn, opts) do
    if raw_field_survey_room_artifact?(conn) do
      conn
    else
      parser_opts = if automation_callback?(conn), do: opts.automation_callback, else: opts.default
      parse(conn, parser_opts)
    end
  end

  defp parse(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    _err in [Plug.Parsers.ParseError, Plug.Parsers.RequestTooLargeError] ->
      send_malformed_request(conn)
  end

  defp raw_field_survey_room_artifact?(%{method: "POST", request_path: request_path}) when is_binary(request_path) do
    String.starts_with?(request_path, "/v1/field-survey/") and
      String.ends_with?(request_path, "/room-artifacts")
  end

  defp raw_field_survey_room_artifact?(_conn), do: false

  defp automation_callback?(%{method: "POST", request_path: request_path}) do
    String.starts_with?(request_path, "/api/v1/automation/callback-grants/") and
      String.ends_with?(request_path, "/actions/remote_access.ssh_ca.bundle.read")
  end

  defp automation_callback?(_conn), do: false

  defp send_malformed_request(conn) do
    if automation_callback?(conn) do
      conn
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.put_resp_header("pragma", "no-cache")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, ~s({"error":"callback_denied"}))
      |> Plug.Conn.halt()
    else
      send_default_malformed_request(conn)
    end
  end

  defp send_default_malformed_request(conn) do
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
