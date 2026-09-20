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

  test "sanitize of a huge logger report stays bounded" do
    huge = Map.new(1..20_000, fn i -> {i, String.duplicate("z", 80)} end)

    batch = %{
      undefined: [
        %{
          level: :warning,
          msg: {:report, %{payload: huge}},
          meta: %{time: System.os_time(:microsecond), payload: huge}
        }
      ]
    }

    sanitized = :otel_exporter_logs_otlp.sanitize_logs_for_export(batch)

    assert %{undefined: [%{meta: metadata, msg: {:report, report}}]} = sanitized
    assert metadata.payload == "<truncated>"
    assert report.payload == "<truncated>"
  end

  test "log handler drops events once the batch hits max_queue_size" do
    reg = :"otel_log_handler_cap_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      :serviceradar_otel_log_handler_v2.start(reg, %{
        id: :otel_log_handler_cap,
        module: :serviceradar_otel_log_handler_v2,
        exporter: :none,
        max_queue_size: 8,
        scheduled_delay_ms: 60_000
      })

    on_exit(fn ->
      if Process.alive?(pid) do
        :gen_statem.stop(reg, :normal, 2_000)
      end
    end)

    event = %{level: :warning, msg: {"overflow", []}, meta: %{time: 1}}
    config = %{regname: reg}

    Enum.each(1..40, fn _ -> :serviceradar_otel_log_handler_v2.log(event, config) end)

    stats =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        Process.sleep(10)
        current = :serviceradar_otel_log_handler_v2.queue_stats(reg)

        if current.batch_len >= 8 do
          {:halt, current}
        else
          {:cont, current}
        end
      end)

    assert stats.batch_len == 8
    assert stats.max_queue_size == 8
    assert stats.mailbox < 40
    {:message_queue_len, qlen} = Process.info(pid, :message_queue_len)
    assert qlen < 40
  end

  test "prepare converts charlist bodies to bounded binaries before to_proto" do
    charlist = "warning body " |> String.duplicate(20_000) |> String.to_charlist()

    batch = %{
      undefined: [
        %{level: :warning, msg: {:string, charlist}, meta: %{time: 1}},
        %{level: :warning, msg: {"~s", [charlist]}, meta: %{time: 2}}
      ]
    }

    prepared = :otel_exporter_logs_otlp.prepare_logs_for_export(batch)
    assert %{undefined: [first, second]} = prepared
    assert {:string, body1} = first.msg
    assert {:string, body2} = second.msg
    assert is_binary(body1) and byte_size(body1) <= 8_192 + byte_size("...[truncated]")
    assert is_binary(body2) and byte_size(body2) <= 8_192 + byte_size("...[truncated]")

    proto = :otel_otlp_logs.to_proto(prepared, :otel_resource.create(%{}), %{})

    assert %{resource_logs: [%{scope_logs: [%{log_records: records}]}]} = proto
    assert length(records) == 2
  end

  test "prepare drops extra events so a backed-up handler cannot encode tens of thousands" do
    events =
      for i <- 1..1_000 do
        %{level: :warning, msg: {:string, "n=#{i}"}, meta: %{time: i}}
      end

    prepared = :otel_exporter_logs_otlp.prepare_logs_for_export(%{undefined: events})
    assert length(prepared.undefined) == 256

    proto = :otel_otlp_logs.to_proto(prepared, :otel_resource.create(%{}), %{})

    assert %{resource_logs: [%{scope_logs: [%{log_records: records}]}]} = proto
    assert length(records) == 256
  end
end
