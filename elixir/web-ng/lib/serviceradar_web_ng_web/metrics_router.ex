defmodule ServiceRadarWebNGWeb.MetricsRouter do
  @moduledoc """
  Minimal Prometheus scrape endpoint for web-ng on an internal-only port.

  Served on a dedicated Bandit listener (default port 9090) that is
  intentionally omitted from public Gateway and Ingress routes.
  """

  use Plug.Router

  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    conn
    |> put_resp_header("content-type", @prometheus_content_type)
    |> send_resp(
      200,
      TelemetryMetricsPrometheus.Core.scrape(ServiceRadarWebNGWeb.Telemetry.prometheus_reporter())
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
