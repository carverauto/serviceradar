defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline

  test "ack/3 invokes ack and nack callbacks" do
    parent = self()

    ack_message = %Message{
      data: "",
      metadata: %{subject: "events.test", reply_to: "$JS.ACK.test"},
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
  end

  test "routes metrics subjects to the declared metrics batcher" do
    message = %Message{
      data: Jason.encode!(%{"metric_name" => "cpu_usage", "value" => 42.0}),
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
end
