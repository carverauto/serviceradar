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
      {:ok, token} when is_binary(configured_token) and configured_token != "" ->
        Plug.Crypto.secure_compare(token, configured_token)

      _ ->
        false
    end
  end

  defp metrics_token do
    case Application.get_env(:serviceradar_web_ng, :metrics_token) do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        case Application.get_env(:serviceradar_web_ng, :metrics_listener) do
          config when is_list(config) ->
            case Keyword.get(config, :token) do
              token when is_binary(token) and token != "" -> token
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 ->
        {:ok, String.trim(token)}

      _ ->
        :error
    end
  end
end
