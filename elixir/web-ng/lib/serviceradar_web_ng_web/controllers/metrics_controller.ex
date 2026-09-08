defmodule ServiceRadarWebNGWeb.MetricsController do
  use ServiceRadarWebNGWeb, :controller

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"
  @sobelow_skip ["XSS.SendResp"]

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", @prometheus_content_type)
    |> send_resp(
      200,
      TelemetryMetricsPrometheus.Core.scrape(ServiceRadarWebNGWeb.Telemetry.prometheus_reporter())
    )
  end
end
