defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.AdhocScan
  alias ServiceRadar.EventWriter.Processors.Mtr

  @moduletag :db_free

  setup do
    handler_id = "pipeline-ack-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :ack],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "ack/3 invokes ack and nack callbacks" do
    parent = self()

    ack_message = %Message{
      data: "",
      metadata: %{
        subject: "events.test",
        reply_to: "$JS.ACK.test",
        received_monotonic: System.monotonic_time()
      },
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn
             :ack ->
               send(parent, :acked)
               :ok

             :nack ->
               send(parent, :nacked)
               :ok
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [ack_message], [ack_message])
    assert_receive :acked
    assert_receive :nacked

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack],
                    %{count: 1, duration: duration},
                    %{action: :ack, result: :ok, subject_class: "events"}}

    assert is_integer(duration) and duration >= 0

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack],
                    %{count: 1, duration: duration},
                    %{action: :nack, result: :ok, subject_class: "events"}}

    assert is_integer(duration) and duration >= 0
  end

  test "ack/3 terminally acknowledges final failed JetStream delivery" do
    parent = self()
    handler_id = "pipeline-dead-letter-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :dead_letter],
      fn event, measurements, metadata, _config ->
        send(parent, {:dead_letter_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    failed_message =
      Message.failed(
        %Message{
          data: "",
          status: {:failed, :db_unavailable},
          metadata: %{
            subject: "signals.analytics.predictions.test",
            reply_to: "$JS.ACK.events.consumer.5.9.8.0.0",
            jetstream_ack: %{stream: "events", consumer: "consumer", delivery_count: 5},
            max_deliver: 5,
            received_monotonic: System.monotonic_time()
          },
          acknowledger:
            {Pipeline, :ack_ref,
             %{
               ack_fun: fn
                 :term ->
                   send(parent, :termed)
                   :ok

                 :nack ->
                   send(parent, :nacked)
                   :ok
               end
             }}
        },
        :db_unavailable
      )

    assert :ok == Pipeline.ack(:ack_ref, [], [failed_message])

    assert_receive :termed
    refute_receive :nacked, 50

    assert_receive {:dead_letter_telemetry, [:serviceradar, :event_writer, :dead_letter],
                    %{count: 1, delivery_count: 5, max_deliver: 5},
                    %{
                      subject_class: "analytics",
                      stream: "events",
                      consumer: "consumer",
                      reason_class: "db_unavailable"
                    }}

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :term, result: :ok, subject_class: "analytics"}}
  end

  test "ack/3 nacks failed messages before max_deliver" do
    parent = self()

    failed_message =
      Message.failed(
        %Message{
          data: "",
          status: {:failed, :transient},
          metadata: %{
            subject: "signals.analytics.predictions.test",
            reply_to: "$JS.ACK.events.consumer.4.9.8.0.0",
            jetstream_ack: %{stream: "events", consumer: "consumer", delivery_count: 4},
            max_deliver: 5
          },
          acknowledger:
            {Pipeline, :ack_ref,
             %{
               ack_fun: fn
                 :term ->
                   send(parent, :termed)
                   :ok

                 :nack ->
                   send(parent, :nacked)
                   :ok
               end
             }}
        },
        :transient
      )

    assert :ok == Pipeline.ack(:ack_ref, [], [failed_message])

    assert_receive :nacked
    refute_receive :termed, 50
  end

  test "ack/3 does not crash when ack callback exits" do
    message = %Message{
      data: "",
      metadata: %{subject: "falco.test", reply_to: "$JS.ACK.falco"},
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn _action ->
             exit(:noprocess)
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [message], [message])

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :ack, result: :error, subject_class: "falco"}}

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :nack, result: :error, subject_class: "falco"}}
  end

  # A stream whose subject has no routing rule still gets a consumer, so its
  # messages arrive, fall through to the Default processor, and are acked and
  # dropped without an error anywhere. MTR and ad-hoc scan results shipped that
  # way.
  test "every default stream's subject reaches the processor its stream declares" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    batchers = Pipeline.configured_batcher_names(config)

    for stream <- Config.default_streams(), not Config.flow_stream?(stream) do
      subject = String.replace(stream.subject, [">", "*"], "example")

      message = %Message{
        data: "",
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      %Message{batcher: batcher} = Pipeline.handle_message(:default, message, %{})

      assert batcher in batchers, "#{stream.name}: #{subject} routes to undeclared #{batcher}"

      assert Pipeline.processor_for_batcher(batcher) == stream.processor,
             "#{stream.name}: #{subject} runs #{inspect(Pipeline.processor_for_batcher(batcher))}"
    end
  end

  test "routes MTR and ad-hoc scan results to their own batchers" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    routes = [
      {"mtr.results.ingest", :mtr_results, Mtr},
      {"scans.results.run01", :scan_results, AdhocScan}
    ]

    for {subject, batcher, processor} <- routes do
      message = %Message{
        data: "",
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      assert batcher in Pipeline.configured_batcher_names(config)
      assert %Message{batcher: ^batcher} = Pipeline.handle_message(:default, message, %{})
      assert Pipeline.processor_for_batcher(batcher) == processor
    end
  end

  test "routes metrics subjects to the declared metrics batcher" do
    message = %Message{
      data: <<10, 22, "serviceradar.metric.v1">>,
      metadata: %{subject: "metrics.sysmon.cpu"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :metrics in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :metrics, metadata: %{base_subject: "metrics.sysmon.cpu"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes analytics prediction subjects to the declared, configured batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    # The ANALYTICS_PREDICTIONS stream builds the `:analytics_predictions` batcher, so the
    # subject router must emit that same atom — otherwise Broadway dispatches to an unknown
    # batcher and crashes. Guards against the stale `:causal_predictions` routing name.
    assert :analytics_predictions in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: Jason.encode!(%{"signal_type" => "prediction"}),
      metadata: %{subject: "signals.analytics.predictions.cpu-series"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{
             batcher: :analytics_predictions,
             metadata: %{base_subject: "signals.analytics.predictions.cpu-series"}
           } = Pipeline.handle_message(:default, message, %{})

    # The generic `signals.analytics.*` catch-all shares the (configured) bmp batcher.
    overlay = %Message{
      data: Jason.encode!(%{"signal_type" => "analytics"}),
      metadata: %{subject: "signals.analytics.overlay"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert :bmp_causal in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :bmp_causal, metadata: %{base_subject: "signals.analytics.overlay"}} =
             Pipeline.handle_message(:default, overlay, %{})
  end

  test "routes processed logs to the declared logs batcher" do
    message = %Message{
      data: Jason.encode!(%{"message" => "internal audit event"}),
      metadata: %{subject: "logs.internal.processed.audit"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :logs in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :logs, metadata: %{base_subject: "logs.internal.processed.audit"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes PowerDNS OCSF to the declared pdns batcher" do
    message = %Message{
      data: Jason.encode!(%{"class_uid" => 4003}),
      metadata: %{subject: "pdns.ocsf"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :pdns_ocsf in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :pdns_ocsf, metadata: %{base_subject: "pdns.ocsf"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes raw Zen log subjects to the declared logs batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :logs in Pipeline.configured_batcher_names(config)

    for subject <- ["logs.syslog", "logs.snmp", "logs.otel"] do
      message = %Message{
        data: Jason.encode!(%{"body" => "test"}),
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      assert %Message{batcher: :logs, metadata: %{base_subject: ^subject}} =
               Pipeline.handle_message(:default, message, %{})
    end
  end

  test "events.flow.attribution uses the flow_attribution batcher even without a dedicated stream" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: [
        %{
          name: "EVENTS",
          stream_name: "events",
          subject: "events.>",
          processor: ServiceRadar.EventWriter.Processors.Events
        }
      ]
    }

    assert :flow_attribution in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: ~s({"id":"flow-alpha-0001","attribution_version":1}),
      metadata: %{subject: "events.flow.attribution"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flow_attribution} = Pipeline.handle_message(:default, message, %{})
  end

  test "does not declare a flow.attributed read-back batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    refute :attributed_flow in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: "",
      metadata: %{subject: "flow.attributed.default"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :default} = Pipeline.handle_message(:default, message, %{})
  end

  test "flow pipeline configures :flows_raw batcher for all raw-flow streams" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 500,
      consumer_name: "test-consumer",
      streams: [
        %{name: "SFLOW_RAW", stream_name: "flows", subject: "flows.raw.sflow"},
        %{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"},
        %{name: "FLOW_RAW_IPFIX", stream_name: "flows", subject: "flows.raw.ipfix"},
        %{
          name: "NETFLOW_RAW_EVENTS_DRAIN",
          stream_name: "events",
          subject: "flows.raw.netflow",
          durable_source_name: "NETFLOW_RAW"
        }
      ]
    }

    names = Pipeline.configured_batcher_names(config)
    assert :flows_raw in names
    refute :sflow_raw in names
    refute :netflow_raw in names
    refute :flow_raw_ipfix in names

    message = %Message{
      data: "{}",
      metadata: %{subject: "flows.raw.netflow"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flows_raw} = Pipeline.handle_message(:default, message, %{})
  end

  # A subject without a routing rule falls to :default, whose processor acks and
  # drops it: observations would never reach the warehouse.
  test "flow pipeline routes attribution observations to their own processor" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 500,
      consumer_name: "test-consumer",
      streams: [
        %{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"},
        %{
          name: "FLOW_ATTRIBUTION_OBSERVATIONS",
          stream_name: "flows",
          subject: "flows.attribution.observations"
        }
      ]
    }

    assert :flow_attribution_observations in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: "{}",
      metadata: %{subject: "flows.attribution.observations"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flow_attribution_observations} =
             Pipeline.handle_message(:default, message, %{})

    assert Pipeline.processor_for_batcher(:flow_attribution_observations) ==
             ServiceRadar.EventWriter.Processors.FlowAttributionObservations
  end

  test "the running OTel topology coalesces sparse spans, splits loads and ACKs after HTTP completion" do
    starrocks = ServiceRadar.Analytics.StarRocks
    previous = Application.get_env(:serviceradar_core, starrocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, starrocks, previous) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_loads(listener, parent) end})
    start_supervised!(LoadSupervisor)

    Application.put_env(:serviceradar_core, starrocks,
      enabled: true,
      fe_http: "http://127.0.0.1:#{port}",
      stream_load: [max_age_ms: 200, max_rows: 2]
    )

    config = %Config{
      enabled: true,
      producer_name: __MODULE__.Producer,
      nats: %{
        host: "127.0.0.1",
        port: 1,
        jwt: "synthetic-token",
        nkey_seed: nil,
        user: nil,
        password: nil,
        tls: false
      },
      batch_size: 100,
      batch_timeout: 1_000,
      max_ack_pending: 8,
      consumer_name: "synthetic-warehouse",
      streams: Config.default_streams()
    }

    start_supervised!({Pipeline, {config, [name: __MODULE__.Topology]}})

    spans =
      for n <- 1..3 do
        Jason.encode!(%{
          "timestamp" => "2000-01-01T00:00:00Z",
          "trace_id" => "00000000000000000000000000000001",
          "span_id" => n |> Integer.to_string(16) |> String.pad_leading(16, "0"),
          "name" => "synthetic"
        })
      end

    ref =
      Broadway.test_batch(__MODULE__.Topology, spans,
        metadata: %{subject: "otel.traces.synthetic"},
        batch_mode: :bulk
      )

    refute_receive {:warehouse_rows, _, _}, 75
    assert_receive {:warehouse_rows, first_http, first_rows}, 650
    assert_receive {:warehouse_rows, second_http, second_rows}, 650
    assert Enum.sort([length(first_rows), length(second_rows)]) == [1, 2]

    assert (first_rows ++ second_rows) |> Enum.map(& &1["span_id"]) |> Enum.sort() ==
             ["0000000000000001", "0000000000000002", "0000000000000003"]

    refute_receive {:ack, ^ref, _, _}, 50
    send(first_http, :commit)
    send(second_http, :commit)
    assert_receive {:ack, ^ref, successful, []}, 1_000
    assert length(successful) == 3

    # Sparse idle traffic must also flush at maxAge, independently of maxRows.
    idle =
      Broadway.test_batch(__MODULE__.Topology, [hd(spans)],
        metadata: %{subject: "otel.traces.synthetic"},
        batch_mode: :bulk
      )

    assert_receive {:warehouse_rows, idle_http, [_]}, 650
    send(idle_http, :commit)
    assert_receive {:ack, ^idle, [_], []}, 1_000
  end

  test "caller cancellation closes the default HTTP request and releases admission" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_loads(listener, parent) end})
    start_supervised!({LoadSupervisor, max_in_flight: 1})
    config = %{fe_http: "http://127.0.0.1:#{port}"}
    rows = [%{"id" => "synthetic-cancellation"}]
    caller = spawn(fn -> StreamLoad.persist("logs", rows, config: config) end)
    assert_receive {:warehouse_rows, http, ^rows}, 1_000
    send(http, :observe_close)
    Process.exit(caller, :kill)
    assert_receive :load_connection_closed, 1_000

    next = Task.async(fn -> StreamLoad.persist("logs", rows, config: config) end)
    assert_receive {:warehouse_rows, next_http, ^rows}, 1_000
    send(next_http, :commit)
    assert {:ok, %{loaded: 1}} = Task.await(next)
  end

  defp serve_loads(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        # Accept the next chunk while this one is waiting for durable commit.
        Task.start_link(fn -> answer_load(socket, parent) end)
        serve_loads(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp answer_load(socket, parent) do
    {:ok, _request_line} = :gen_tcp.recv(socket, 0, 5_000)
    bytes = load_headers(socket, 0)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, bytes, 5_000)
    rows = Jason.decode!(body)
    send(parent, {:warehouse_rows, self(), rows})

    receive do
      :observe_close ->
        {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :load_connection_closed)

      :commit ->
        response =
          Jason.encode!(%{
            "Status" => "Success",
            "NumberLoadedRows" => length(rows),
            "NumberFilteredRows" => 0
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])
    after
      5_000 -> raise "synthetic HTTP load was never committed"
    end

    :gen_tcp.close(socket)
  end

  defp load_headers(socket, bytes) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    case String.split(String.trim(line), ":", parts: 2) do
      [""] ->
        bytes

      [key, value] ->
        if String.downcase(key) == "content-length",
          do: load_headers(socket, value |> String.trim() |> String.to_integer()),
          else: load_headers(socket, bytes)
    end
  end

  describe "warehouse batch sizing" do
    @batchers [
      metrics: [batch_size: 100, batch_timeout: 1_000],
      falco: [batch_size: 100, batch_timeout: 1_000],
      otel_traces: [batch_size: 100, batch_timeout: 1_000],
      otel_metrics: [batch_size: 100, batch_timeout: 1_000],
      logs: [batch_size: 500, batch_timeout: 10_000]
    ]

    @metrics_batchers [metrics: [batch_size: 500, batch_timeout: 500]]

    @sizing %{
      max_ack_pending: 256,
      max_age_ms: 2_000,
      max_rows: 50_000,
      max_bytes: 1,
      max_in_flight: 4
    }

    test "without the warehouse the batchers are left as configured" do
      assert Pipeline.size_warehouse_batchers(@batchers, %Config{streams: []}, nil) == @batchers
    end

    test "warehouse batchers flush on the load max age and fill to half of max_ack_pending" do
      sized = Pipeline.size_warehouse_batchers(@batchers, %Config{streams: []}, @sizing)

      assert sized[:metrics] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:falco] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:otel_traces] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:otel_metrics] == [batch_size: 128, batch_timeout: 2_000]
      # The maximum age also caps a longer CNPG timeout.
      assert sized[:logs] == [batch_size: 128, batch_timeout: 2_000]
    end

    test "a configured batch size the consumer cannot deliver is capped" do
      sized = Pipeline.size_warehouse_batchers(@metrics_batchers, %Config{streams: []}, @sizing)

      assert sized[:metrics] == [batch_size: 128, batch_timeout: 2_000]
    end

    test "batch size is left as configured when max_ack_pending is unknown" do
      sizing = %{@sizing | max_ack_pending: nil}
      sized = Pipeline.size_warehouse_batchers(@metrics_batchers, %Config{streams: []}, sizing)

      assert sized[:metrics] == [batch_size: 500, batch_timeout: 2_000]
    end

    test "a stream's own max_ack_pending bounds its batcher" do
      config = %Config{
        streams: [
          %{
            name: "METRICS",
            subject: "metrics.>",
            processor: nil,
            consumer_max_ack_pending: 2_048
          }
        ]
      }

      sized = Pipeline.size_warehouse_batchers(@batchers, config, @sizing)

      assert sized[:metrics][:batch_size] == 1_024
      assert sized[:falco][:batch_size] == 128
    end
  end
end
