defmodule ServiceRadar.EventWriter.JetStreamAckTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.JetStreamAck

  test "parses standard JetStream ack reply subjects" do
    assert %{
             stream: "events",
             consumer: "consumer",
             delivery_count: 5,
             stream_sequence: 42,
             consumer_sequence: 7,
             timestamp: 1_812_345_678,
             pending: 3
           } = JetStreamAck.parse("$JS.ACK.events.consumer.5.42.7.1812345678.3")
  end

  test "parses domain or account prefixed ack reply subjects from the right" do
    assert %{
             stream: "events",
             consumer: "serviceradar",
             delivery_count: 2,
             stream_sequence: 10,
             consumer_sequence: 9,
             timestamp: 8,
             pending: 7
           } = JetStreamAck.parse("$JS.ACK.domain.account.events.serviceradar.2.10.9.8.7")
  end

  test "returns nil for malformed reply subjects" do
    assert JetStreamAck.parse(nil) == nil
    assert JetStreamAck.parse("events.consumer.1.2.3.4.5") == nil
    assert JetStreamAck.parse("$JS.ACK.events.consumer.0.1.1.1.0") == nil
    assert JetStreamAck.parse("$JS.ACK.events.consumer.one.1.1.1.0") == nil
  end
end
