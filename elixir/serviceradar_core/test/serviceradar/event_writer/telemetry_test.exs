defmodule ServiceRadar.EventWriter.TelemetryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Telemetry

  defp attach_telemetry(events) do
    handler_id = "event-writer-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "subject_class/1" do
    test "collapses subjects to bounded classes" do
      assert Telemetry.subject_class("metrics.sysmon.cpu") == "metrics"
      assert Telemetry.subject_class("otel.metrics.raw") == "otel_metrics"
      assert Telemetry.subject_class("otel.traces.raw") == "otel_traces"
      assert Telemetry.subject_class("otel.logs.raw") == "otel_logs"
      assert Telemetry.subject_class("logs.syslog") == "logs"
      assert Telemetry.subject_class("events.poller") == "events"
      assert Telemetry.subject_class("flows.netflow") == "flows"
      assert Telemetry.subject_class("flow.attributed.default") == "flows"
      assert Telemetry.subject_class("pdns.ocsf") == "pdns"
      assert Telemetry.subject_class("falco.alert") == "falco"
      assert Telemetry.subject_class("trivy.report") == "trivy"
      assert Telemetry.subject_class("sweep.result") == "sweep"
      assert Telemetry.subject_class("signals.analytics.predictions.cpu") == "analytics"
      assert Telemetry.subject_class("signals.analytics.inventory.added") == "analytics"
      assert Telemetry.subject_class("causal.signal") == "causal"
      assert Telemetry.subject_class("unknown.subject") == "other"
      assert Telemetry.subject_class(nil) == "unknown"
    end
  end

  describe "consumer_state_measurements/1" do
    test "combines consumer backlog with authoritative stream retention gauges" do
      info = %{
        num_pending: 10,
        num_ack_pending: 3,
        num_redelivered: 1,
        num_waiting: 2,
        delivered: %{consumer_seq: 42, stream_seq: 100},
        ack_floor: %{consumer_seq: 39, stream_seq: 97}
      }

      now = ~U[2026-08-10 12:00:00Z]

      stream_info = %{
        config: %{max_bytes: 1_000, max_age: 120_000_000_000},
        state: %{bytes: 800, messages: 20, first_ts: ~U[2026-08-10 11:59:30Z]}
      }

      assert Telemetry.consumer_state_measurements(info, stream_info, now) == %{
               pending_messages: 10,
               ack_pending_messages: 3,
               redelivered_messages: 1,
               waiting_pulls: 2,
               lag_messages: 13,
               delivered_consumer_sequence: 42,
               ack_floor_consumer_sequence: 39,
               delivered_stream_sequence: 100,
               ack_floor_stream_sequence: 97,
               stream_info_available: 1,
               stream_bytes: 800,
               stream_max_bytes: 1_000,
               stream_byte_utilization_ratio: 0.8,
               stream_first_message_age_seconds: 30.0,
               stream_max_age_seconds: 120.0,
               stream_age_utilization_ratio: 0.25,
               retention_risk_level: 1
             }
    end

    test "elevates risk only when backlog coexists with critical stream utilization" do
      now = ~U[2026-08-10 12:00:00Z]

      stream_info = %{
        config: %{max_bytes: 1_000, max_age: 100_000_000_000},
        state: %{bytes: 950, messages: 20, first_ts: ~U[2026-08-10 11:58:40Z]}
      }

      assert %{retention_risk_level: 2} =
               Telemetry.consumer_state_measurements(
                 %{num_pending: 1},
                 stream_info,
                 now
               )

      assert %{retention_risk_level: 0} =
               Telemetry.consumer_state_measurements(
                 %{num_pending: 0, num_ack_pending: 0},
                 stream_info,
                 now
               )
    end

    test "accepts string-keyed info and clamps missing values" do
      assert Telemetry.consumer_state_measurements(%{"num_pending" => 0}) == %{
               pending_messages: 0,
               ack_pending_messages: 0,
               redelivered_messages: 0,
               waiting_pulls: 0,
               lag_messages: 0,
               delivered_consumer_sequence: 0,
               ack_floor_consumer_sequence: 0,
               delivered_stream_sequence: 0,
               ack_floor_stream_sequence: 0,
               stream_info_available: 0,
               stream_bytes: 0,
               stream_max_bytes: 0,
               stream_byte_utilization_ratio: 0.0,
               stream_first_message_age_seconds: 0.0,
               stream_max_age_seconds: 0.0,
               stream_age_utilization_ratio: 0.0,
               retention_risk_level: 0
             }
    end
  end

  describe "consumer state telemetry" do
    test "emits bounded consumer state metadata" do
      attach_telemetry([[:serviceradar, :event_writer, :consumer, :state]])

      :ok =
        Telemetry.emit_consumer_state(
          %{num_pending: 7, num_ack_pending: 2, num_redelivered: 0, num_waiting: 1},
          %{
            config: %{max_bytes: 1_000, max_age: 60_000_000_000},
            state: %{bytes: 900, messages: 1, first_ts: DateTime.utc_now()}
          },
          %{
            stream: "metrics",
            durable: "serviceradar-event-writer-metrics",
            subject_class: "metrics"
          }
        )

      assert_receive {:telemetry, [:serviceradar, :event_writer, :consumer, :state],
                      %{
                        pending_messages: 7,
                        ack_pending_messages: 2,
                        lag_messages: 9,
                        stream_info_available: 1,
                        stream_bytes: 900,
                        stream_max_bytes: 1_000,
                        stream_byte_utilization_ratio: 0.9
                      },
                      %{
                        stream: "metrics",
                        durable: "serviceradar-event-writer-metrics",
                        subject_class: "metrics"
                      }}
    end

    test "emits bounded poll error metadata" do
      attach_telemetry([[:serviceradar, :event_writer, :consumer, :poll_error]])

      :ok =
        Telemetry.emit_consumer_state_error(
          {:exit, :timeout},
          %{
            stream: "metrics",
            durable: "serviceradar-event-writer-metrics",
            subject_class: "metrics"
          }
        )

      assert_receive {:telemetry, [:serviceradar, :event_writer, :consumer, :poll_error],
                      %{count: 1},
                      %{
                        stream: "metrics",
                        durable: "serviceradar-event-writer-metrics",
                        subject_class: "metrics",
                        reason_class: "exit"
                      }}
    end
  end
end
