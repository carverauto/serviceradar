defmodule ServiceRadarCoreElx.MetricsRouter do
  @moduledoc """
  Minimal Prometheus scrape endpoint for Core-ELX.
  """

  use Plug.Router

  @default_ip {0, 0, 0, 0}
  @default_port 9090
  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    conn
    |> put_resp_header("content-type", @prometheus_content_type)
    |> send_resp(
      200,
      TelemetryMetricsPrometheus.Core.scrape(ServiceRadarCoreElx.Telemetry.prometheus_reporter())
    )
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
