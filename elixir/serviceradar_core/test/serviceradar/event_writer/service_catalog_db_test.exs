defmodule ServiceRadar.EventWriter.ServiceCatalogDbTest do
  @moduledoc """
  The OTel service catalog upsert against CNPG, and its wiring into the logs,
  traces and metrics processors.

  No `ServiceCatalogCache` runs here, so every call reaches the database; the
  throttling contract is covered in `service_catalog_test.exs`.
  """

  use ServiceRadar.DataCase, async: true

  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.EventWriter.Processors.OtelMetrics
  alias ServiceRadar.EventWriter.Processors.OtelTraces
  alias ServiceRadar.EventWriter.ServiceCatalog
  alias ServiceRadar.Repo

  defp unique_service(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp catalog_row(service_name) do
    case Repo.query!(
           """
           SELECT logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at, last_seen_at
           FROM platform.otel_service_catalog
           WHERE service_name = $1
           """,
           [service_name]
         ) do
      %{rows: [[logs, traces, metrics, last]]} ->
        %{logs: logs, traces: traces, metrics: metrics, last: last}

      %{rows: []} ->
        nil
    end
  end

  defp at(seconds), do: DateTime.add(~U[2026-01-01 00:00:00.000000Z], seconds, :second)

  describe "record/3" do
    test "creates a service with only the reporting signal's column set" do
      name = unique_service("checkout")

      assert {:ok, 1} = ServiceCatalog.record(:traces, [%{service_name: name}], now: at(0))

      assert %{logs: nil, traces: traces, metrics: nil, last: last} = catalog_row(name)
      assert DateTime.compare(traces, at(0)) == :eq
      assert DateTime.compare(last, at(0)) == :eq
    end

    test "advances one signal without touching the others" do
      name = unique_service("billing")

      assert {:ok, 1} = ServiceCatalog.record(:traces, [%{service_name: name}], now: at(0))
      assert {:ok, 1} = ServiceCatalog.record(:logs, [%{service_name: name}], now: at(60))

      assert %{logs: logs, traces: traces, metrics: nil, last: last} = catalog_row(name)
      assert DateTime.compare(logs, at(60)) == :eq
      assert DateTime.compare(traces, at(0)) == :eq
      assert DateTime.compare(last, at(60)) == :eq
    end

    test "an older observation neither moves a timestamp back nor rewrites the row" do
      name = unique_service("svc")

      assert {:ok, 1} = ServiceCatalog.record(:metrics, [%{service_name: name}], now: at(120))
      assert {:ok, 0} = ServiceCatalog.record(:metrics, [%{service_name: name}], now: at(60))

      assert %{metrics: metrics, last: last} = catalog_row(name)
      assert DateTime.compare(metrics, at(120)) == :eq
      assert DateTime.compare(last, at(120)) == :eq
    end
  end

  describe "processors record the services of a persisted batch" do
    test "logs" do
      name = unique_service("checkout")

      message = %{
        data:
          Jason.encode!(%{
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
            "severity_text" => "INFO",
            "body" => "service catalog probe",
            "service_name" => name
          }),
        metadata: %{subject: "logs.service-catalog-test", received_at: DateTime.utc_now()}
      }

      assert {:ok, 1} = Logs.process_batch([message])
      assert %{logs: %DateTime{}, traces: nil, metrics: nil} = catalog_row(name)
    end

    test "otel_traces" do
      name = unique_service("checkout")
      now_ns = System.os_time(:nanosecond)

      message = %{
        data:
          Jason.encode!(%{
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
            "trace_id" => "0af7651916cd43dd8448eb211c80319c",
            "span_id" => "b7ad6b7169203331",
            "name" => "GET /cart",
            "kind" => 2,
            "start_time_unix_nano" => now_ns,
            "end_time_unix_nano" => now_ns + 1_000_000,
            "service_name" => name
          }),
        metadata: %{subject: "otel.traces.service-catalog-test"}
      }

      assert {:ok, 1} = OtelTraces.process_batch([message])
      assert %{logs: nil, traces: %DateTime{}, metrics: nil} = catalog_row(name)
    end

    test "otel_metrics, for OTLP metric points" do
      name = unique_service("billing")

      request = %ExportMetricsServiceRequest{
        resource_metrics: [
          %ResourceMetrics{
            resource: %Resource{
              attributes: [
                %KeyValue{key: "service.name", value: %AnyValue{value: {:string_value, name}}}
              ]
            },
            scope_metrics: [
              %ScopeMetrics{
                metrics: [
                  %Metric{
                    name: "queue_depth",
                    data:
                      {:gauge,
                       %Gauge{
                         data_points: [
                           %NumberDataPoint{
                             time_unix_nano: System.os_time(:nanosecond),
                             value: {:as_double, 3.0}
                           }
                         ]
                       }}
                  }
                ]
              }
            ]
          }
        ]
      }

      message = %{data: ExportMetricsServiceRequest.encode(request), metadata: %{}}

      assert {:ok, 1} = OtelMetrics.process_batch([message])
      assert %{logs: nil, traces: nil, metrics: %DateTime{}} = catalog_row(name)
    end
  end
end
