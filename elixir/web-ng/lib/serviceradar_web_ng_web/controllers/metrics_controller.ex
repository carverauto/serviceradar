defmodule ServiceRadarWebNGWeb.MetricsController do
  use ServiceRadarWebNGWeb, :controller

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"
  @sobelow_skip ["XSS.SendResp"]

  def index(conn, _params) do
    if authorized?(conn) do
      conn
      |> put_resp_header("content-type", @prometheus_content_type)
      |> send_resp(
        200,
        TelemetryMetricsPrometheus.Core.scrape(ServiceRadarWebNGWeb.Telemetry.prometheus_reporter())
      )
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    end
  end

  defp authorized?(conn) do
    configured_token = metrics_token()

    case get_bearer_token(conn) do
      {:ok, token} when is_binary(configured_token) ->
        secure_equal?(token, configured_token)

      _ ->
        false
    end
  end

  defp metrics_token do
    case normalize_token(Application.get_env(:serviceradar_web_ng, :metrics_token)) do
      token when is_binary(token) ->
        token

      _ ->
        case Application.get_env(:serviceradar_web_ng, :metrics_listener) do
          config when is_list(config) -> normalize_token(Keyword.get(config, :token))
          _ -> nil
        end
    end
  end

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token(_), do: nil

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_, _), do: false

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case String.trim(token) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end
end
