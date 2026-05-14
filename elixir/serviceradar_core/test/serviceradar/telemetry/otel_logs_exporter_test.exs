defmodule ServiceRadar.Telemetry.OtelLogsExporterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentCommandBus

  test "sanitizes complex logger reports before OTLP conversion" do
    response = %{
      __struct__: Monitoring.AgentConfigResponse,
      config_json: String.duplicate("x", 20_000),
      nested: %{pid: self(), tuple: {:push_config, [1, 2, 3]}}
    }

    improper_list = [?i, ?n, ?v, ?a, ?l, ?i, ?d | :tail]

    batch = %{
      undefined: [
        %{
          level: :warning,
          msg:
            {:report,
             %{
               source: :exporter,
               during: :export,
               kind: :error,
               reason: {:bad_generator, improper_list},
               config: response,
               stacktrace: [{AgentCommandBus, :push_config, [response], []}]
             }},
          meta: %{
            time: System.os_time(:microsecond),
            pid: self(),
            reason: {:bad_generator, improper_list},
            response: response,
            stacktrace: [{AgentCommandBus, :push_config, [response], []}]
          }
        }
      ]
    }

    sanitized = :otel_exporter_logs_otlp.sanitize_logs_for_export(batch)

    assert %{undefined: [%{meta: metadata, msg: {:report, report}}]} = sanitized
    assert is_binary(metadata.pid)
    assert is_binary(metadata.reason)
    assert byte_size(metadata.response) <= 2_048 + byte_size("...[truncated]")
    assert is_binary(report.config)
    assert is_binary(report.reason)
    assert byte_size(report.config) <= 8_192 + byte_size("...[truncated]")

    resource = :otel_resource.create(%{})

    assert %{resource_logs: [_]} = :otel_otlp_logs.to_proto(sanitized, resource, %{})
  end
end
