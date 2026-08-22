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

  describe "publish_record/2 and derive/1" do
    import Bitwise

    defp uuidv7(seed) do
      bytes = Enum.map(0..15, &rem(seed + &1, 256))

      bytes
      |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
      |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
      |> :erlang.list_to_binary()
    end

    defp publication(overrides \\ %{}) do
      Map.merge(
        %{
          slot: %{
            network_scope_id: uuidv7(0x40),
            authenticated_agent_id: "agent-0",
            spool_id: uuidv7(0x01),
            sequence: 7
          },
          record_bytes: "the-canonical-record-bytes",
          record_sha256: :binary.copy(<<0xBB>>, 32),
          semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32),
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
        },
        overrides
      )
    end

    defp header(headers, name) do
      Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)
    end

    test "derives the subject, expected stream, and the canonical header set" do
      assert {:ok, d} = JetStreamPublisher.derive(publication())

      assert d.subject =~ ~r"^sr\.edge\.v1\.records\.bulk\.p\d{2}\.v1$"
      assert d.expected_stream == "EDGE_RECORDS_BULK_V1"
      assert header(d.headers, "Nats-Expected-Stream") == d.expected_stream

      # Exactly the transport set -- the semantic envelope is committed inside the msg id, not
      # re-exported as headers.
      assert Enum.map(d.headers, &elem(&1, 0)) |> Enum.sort() ==
               [
                 "Nats-Expected-Stream",
                 "Nats-Msg-Id",
                 "Sr-Edge-Delivery-Id",
                 "Sr-Edge-Transport-Provenance"
               ]

      for {_k, v} <- d.headers, do: assert(is_binary(v) and v != "")
    end

    test "publishes the record bytes UNCHANGED, never a wrapper" do
      with_reply({:ok, %{body: ~s({"stream":"EDGE_RECORDS_BULK_V1","seq":3})}})
      pub = publication()

      assert {:ok, %{seq: 3}} = JetStreamPublisher.publish_record(pub, connection: FakeConn)

      assert_received {:requested, subject, payload, _opts}
      assert payload == pub.record_bytes
      assert subject =~ "sr.edge.v1.records.bulk."
    end

    test "the msg id changes when the record bytes change, so a reused slot cannot collide" do
      {:ok, a} = JetStreamPublisher.derive(publication())

      {:ok, b} =
        JetStreamPublisher.derive(publication(%{record_sha256: :binary.copy(<<0xCC>>, 32)}))

      refute header(a.headers, "Nats-Msg-Id") == header(b.headers, "Nats-Msg-Id")

      # The delivery id addresses the SLOT, so it is unchanged by the payload. If this ever
      # tracked the record, a retry of the same slot would look like a new delivery.
      assert header(a.headers, "Sr-Edge-Delivery-Id") == header(b.headers, "Sr-Edge-Delivery-Id")
    end

    test "the same publication derives identically, which is what makes a replay a duplicate" do
      assert JetStreamPublisher.derive(publication()) ==
               JetStreamPublisher.derive(publication())
    end

    test "a different sequence is a different msg id and a different delivery id" do
      {:ok, a} = JetStreamPublisher.derive(publication())
      slot = publication().slot
      {:ok, b} = JetStreamPublisher.derive(publication(%{slot: %{slot | sequence: 8}}))

      refute header(a.headers, "Nats-Msg-Id") == header(b.headers, "Nats-Msg-Id")
      refute header(a.headers, "Sr-Edge-Delivery-Id") == header(b.headers, "Sr-Edge-Delivery-Id")
    end

    test "an unroutable grant is a derivation error, not a publish attempt" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      pub = publication(%{traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED})

      assert {:error, {:derivation, :unroutable_lane}} =
               JetStreamPublisher.publish_record(pub, connection: FakeConn)

      # NOT VACUOUS: proves it never reached the broker. A derivation failure that still
      # published would put a record on a subject nobody could have computed.
      refute_received {:requested, _, _, _}
    end

    test "a malformed slot is a derivation error, never a published record" do
      for bad <- [
            %{slot: %{publication().slot | sequence: 0}},
            %{slot: %{publication().slot | authenticated_agent_id: "not a principal!"}},
            %{slot: %{publication().slot | spool_id: <<0::128>>}},
            %{record_sha256: <<1, 2, 3>>},
            %{semantic_envelope_sha256: <<>>}
          ] do
        assert {:error, {:derivation, _}} = JetStreamPublisher.derive(publication(bad)),
               "expected #{inspect(Map.keys(bad))} to fail derivation"
      end

      refute_received {:requested, _, _, _}
    end

    test "an absent routing key is refused rather than silently routed to partition 0" do
      slot = Map.delete(publication().slot, :network_scope_id)

      assert {:error, {:derivation, _}} = JetStreamPublisher.derive(publication(%{slot: slot}))
    end
  end
end
