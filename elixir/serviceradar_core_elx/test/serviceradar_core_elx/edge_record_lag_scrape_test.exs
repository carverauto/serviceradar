ExUnit.start()

defmodule ServiceRadarCoreElx.EdgeRecordLagScrapeTest do
  @moduledoc """
  Scrapes the Core-ELX metrics plug after the EventWriter lag path classifies
  an EDGE_RECORD consumer.

  Lag is pending messages plus delivered-but-unacked messages, the sum
  `consumer_state_measurements/3` documents. 4 pending and 2 unacked must
  scrape as 6. A sweep subject must stay out of the edge_record series.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerLagReporter
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry

  setup do
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:inets)
    Application.load(:plug)
    Application.put_env(:plug, :validate_header_keys_during_test, true)

    start_supervised!(ServiceRadarCoreElx.Telemetry)

    {:ok, server} =
      Bandit.start_link(
        plug: ServiceRadarCoreElx.MetricsRouter,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :shutdown) end)
    %{port: port}
  end

  test "EDGE_RECORD backlog is scraped under subject_class edge_record", %{port: port} do
    config = %Config{
      enabled: true,
      nats: %{host: "127.0.0.1", port: 4222, tls: false},
      batch_size: 1,
      batch_timeout: 1_000,
      consumer_name: "serviceradar-event-writer",
      producer_name: nil,
      streams: [
        Config.edge_record_stream(),
        %{
          name: "SWEEP",
          stream_name: "events",
          subject: "sweep.result.>",
          processor: ServiceRadar.EventWriter.Processors.Sweep
        }
      ],
      consumer_pull_batch_size: 1,
      max_ack_pending: 1,
      processor_concurrency: 1,
      ack_wait_ns: 1,
      max_deliver: 1,
      consumer_lag_poll_interval_ms: 30_000
    }

    refs = ConsumerLagReporter.consumer_refs(config)
    edge = Enum.find(refs, &(&1.subject_class == "edge_record"))
    sweep = Enum.find(refs, &(&1.stream == "events"))

    assert edge.stream == "TELEMETRY_EDGE_RECORD_V1_BULK"
    assert edge.durable == "serviceradar-event-writer-edge-record"
    assert sweep.subject_class == "sweep"

    assert ConsumerLagReporter.retention_stream_names(refs) == ["TELEMETRY_EDGE_RECORD_V1_BULK"]

    # JetStream consumer INFO fields. Lag must be pending + ack pending.
    EventWriterTelemetry.emit_consumer_state(
      %{num_pending: 4, num_ack_pending: 2},
      edge
    )

    EventWriterTelemetry.emit_consumer_state(
      %{num_pending: 9, num_ack_pending: 0},
      sweep
    )

    body = scrape(port)

    assert_gauge(body, "edge_record", "serviceradar-event-writer-edge-record", 6)
    assert_gauge(body, "sweep", sweep.durable, 9)

    edge_lines =
      body
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ "serviceradar_event_writer_consumer_lag_messages_value" and &1 =~ ~s(subject_class="edge_record")))

    assert length(edge_lines) == 1
    refute Enum.any?(edge_lines, &(&1 =~ ~s(subject_class="sweep")))
  end

  defp assert_gauge(body, subject_class, durable, value) do
    line =
      body
      |> String.split("\n")
      |> Enum.find(fn row ->
        String.starts_with?(row, "serviceradar_event_writer_consumer_lag_messages_value{") and
          row =~ ~s(subject_class="#{subject_class}") and row =~ ~s(durable="#{durable}")
      end)

    assert line != nil, "missing lag series subject_class=#{subject_class}:\n#{body}"

    scraped =
      line
      |> String.split(" ")
      |> List.last()
      |> String.trim()
      |> Float.parse()

    assert scraped == {value / 1, ""}, line
  end

  defp scrape(port) do
    url = ~c"http://127.0.0.1:#{port}/metrics"
    assert {:ok, {{_, 200, _}, _headers, body}} = :httpc.request(:get, {url, []}, [], [])
    to_string(body)
  end
end
