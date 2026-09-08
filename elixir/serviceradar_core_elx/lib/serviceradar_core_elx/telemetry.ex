defmodule ServiceRadarCoreElx.Telemetry do
  @moduledoc """
  Prometheus telemetry reporter for the Core-ELX runtime.

  Core-ELX owns cluster coordination and camera relay processing, so it exports
  the shared ServiceRadar telemetry set through a local Prometheus reporter.
  """

  use Supervisor

  alias ServiceRadar.Telemetry, as: ServiceRadarTelemetry

  @prometheus_reporter :serviceradar_core_elx_prometheus_metrics

  @spec prometheus_reporter() :: atom()
  def prometheus_reporter, do: @prometheus_reporter

  @spec metrics() :: list()
  def metrics, do: ServiceRadarTelemetry.metrics()

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: @prometheus_reporter, start_async: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
