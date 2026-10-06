defmodule ServiceRadarWebNGWeb.MetricsRouter do
  @moduledoc """
  Minimal Prometheus scrape endpoint for web-ng on an internal-only port.

  Served on a dedicated Bandit listener (default port 9090) that is
  intentionally omitted from public Gateway and Ingress routes.
  """

  use Plug.Router

  @default_ip {0, 0, 0, 0}
  @default_port 9090
  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    reporter = ServiceRadarWebNGWeb.Telemetry.prometheus_reporter()

    body =
      if Process.whereis(reporter) do
        TelemetryMetricsPrometheus.Core.scrape(reporter)
      else
        ""
      end

    conn
    |> put_resp_header("content-type", @prometheus_content_type)
    |> send_resp(200, body)
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  def child_spec(opts) do
    bandit_opts = [
      plug: __MODULE__,
      scheme: :http,
      ip: Keyword.get(opts, :ip, @default_ip),
      port: Keyword.get(opts, :port, @default_port)
    ]

    Supervisor.child_spec(Bandit.child_spec(bandit_opts), id: __MODULE__)
  end
end
