defmodule ServiceRadarAgentGateway.JetStreamPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.JetStreamPublisher

  # A fake connection module driven by the test process mailbox: it records the
  # request and returns a canned reply.
  defmodule FakeConn do
    @moduledoc false
    def request(subject, payload, opts) do
      send(self(), {:requested, subject, payload, opts})
      reply = Process.get(:fake_reply)
      reply
    end
  end

  defp with_reply(reply), do: Process.put(:fake_reply, reply)

  describe "parse_ack/1" do
    test "parses a success PubAck" do
      body = ~s({"stream":"EDGE_SWEEP_BULK_V1","seq":42})

      assert {:ok, %{stream: "EDGE_SWEEP_BULK_V1", seq: 42, duplicate: false}} =
               JetStreamPublisher.parse_ack(body)
    end

    test "parses a duplicate PubAck" do
      body = ~s({"stream":"S","seq":7,"duplicate":true})
      assert {:ok, %{seq: 7, duplicate: true}} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies a capacity (503) error as retryable capacity" do
      body = ~s({"error":{"code":503,"description":"no responders available"}})
      assert {:error, :capacity} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies maximum-messages-exceeded as capacity" do
      body = ~s({"error":{"code":400,"description":"maximum messages exceeded"}})
      assert {:error, :capacity} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies an expected-stream mismatch as a protocol error" do
      body = ~s({"error":{"code":400,"description":"expected stream does not match"}})
      assert {:error, :protocol} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies an unknown error as permanent" do
      body = ~s({"error":{"code":400,"description":"message size exceeds maximum"}})
      assert {:error, :permanent} = JetStreamPublisher.parse_ack(body)
    end

    test "a non-ack body is a protocol error" do
      assert {:error, :protocol} = JetStreamPublisher.parse_ack("not json")
      assert {:error, :protocol} = JetStreamPublisher.parse_ack(~s({"unexpected":true}))
    end
  end

  describe "publish/4" do
    test "returns the parsed PubAck on a durable ack and forwards headers" do
      with_reply({:ok, %{body: ~s({"stream":"EDGE_SWEEP_BULK_V1","seq":9})}})
      headers = [{"Nats-Msg-Id", "abc"}, {"Nats-Expected-Stream", "EDGE_SWEEP_BULK_V1"}]

      assert {:ok, %{stream: "EDGE_SWEEP_BULK_V1", seq: 9}} =
               JetStreamPublisher.publish("sr.edge.v1.sweep.bulk.p00.v1", "payload", headers, connection: FakeConn)

      assert_received {:requested, "sr.edge.v1.sweep.bulk.p00.v1", "payload", opts}
      assert Keyword.get(opts, :headers) == headers
    end

    test "a request timeout is a retryable timeout error" do
      with_reply({:error, :timeout})

      assert {:error, :timeout} =
               JetStreamPublisher.publish("s", "p", [], connection: FakeConn)

      assert JetStreamPublisher.retryable?(:timeout)
    end

    test "a dead/absent connection is retryable capacity, never durable success" do
      with_reply({:error, {:nats_not_connected, :down}})

      assert {:error, :capacity} =
               JetStreamPublisher.publish("s", "p", [], connection: FakeConn)
    end
  end

  test "retryable? classification" do
    assert JetStreamPublisher.retryable?(:capacity)
    assert JetStreamPublisher.retryable?(:timeout)
    refute JetStreamPublisher.retryable?(:protocol)
    refute JetStreamPublisher.retryable?(:permanent)
  end
end
