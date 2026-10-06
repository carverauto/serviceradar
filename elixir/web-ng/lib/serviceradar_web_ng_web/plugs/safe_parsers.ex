defmodule ServiceRadarWebNGWeb.Plugs.SafeParsers do
  @moduledoc false

  @behaviour Plug

  alias ServiceRadarWebNGWeb.NotificationCallbackBody

  # Routes that do not accept a package upload. A 5 MB device CSV still fits.
  # Package publish keeps the endpoint envelope (50 MB renderer plus framing).
  @ordinary_multipart_length 8_388_608

  @impl true
  def init(opts) do
    configured_length = Keyword.get(opts, :length, @ordinary_multipart_length)

    %{
      default: Plug.Parsers.init(opts),
      ordinary_multipart:
        opts
        |> Keyword.put(:length, min(configured_length, @ordinary_multipart_length))
        |> Plug.Parsers.init(),
      notification_callback:
        opts
        |> Keyword.put(:parsers, [:urlencoded, :json])
        |> Keyword.put(:pass, [])
        |> Keyword.put(:length, NotificationCallbackBody.limit())
        |> Keyword.put(:read_length, 65_536)
        |> Plug.Parsers.init(),
      automation_callback: Plug.Parsers.init(Keyword.put(opts, :length, 4_096))
    }
  end

  @impl true
  def call(conn, opts) do
    if raw_field_survey_room_artifact?(conn) do
      conn
    else
      parser_opts =
        cond do
          NotificationCallbackBody.callback?(conn) -> opts.notification_callback
          automation_callback?(conn) -> opts.automation_callback
          ordinary_multipart?(conn) -> opts.ordinary_multipart
          true -> opts.default
        end

      parse(conn, parser_opts)
    end
  end

  defp parse(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    _err in [
      Plug.Parsers.ParseError,
      Plug.Parsers.RequestTooLargeError,
      Plug.Parsers.UnsupportedMediaTypeError
    ] ->
      send_malformed_request(conn)
  end

  defp raw_field_survey_room_artifact?(%{method: "POST", request_path: request_path}) when is_binary(request_path) do
    String.starts_with?(request_path, "/v1/field-survey/") and
      String.ends_with?(request_path, "/room-artifacts")
  end

  defp raw_field_survey_room_artifact?(_conn), do: false

  defp ordinary_multipart?(conn) do
    multipart?(conn) and not large_package_upload?(conn.request_path)
  end

  defp multipart?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "multipart/"))
  end

  # LiveView package uploads POST back to the LiveView path. The CLI publish
  # route is the only other multipart body that carries a renderer archive.
  defp large_package_upload?(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["api", "v1", "dashboard-packages"] -> true
      ["admin", "plugins" | _] -> true
      ["settings", "agents", "plugins" | _] -> true
      ["settings", "dashboards", "packages" | _] -> true
      _ -> false
    end
  end

  defp large_package_upload?(_path), do: false

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
