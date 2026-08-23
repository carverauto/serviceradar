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
      body = ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_BULK","seq":42})

      assert {:ok, %{stream: "TELEMETRY_EDGE_RECORD_V1_BULK", seq: 42, duplicate: false}} =
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

  test "retryable? classification" do
    assert JetStreamPublisher.retryable?(:capacity)
    assert JetStreamPublisher.retryable?(:timeout)
    refute JetStreamPublisher.retryable?(:protocol)
    refute JetStreamPublisher.retryable?(:permanent)
  end

  describe "publish_record/3" do
    import Bitwise

    alias ServiceRadar.Edge.ResolvedRoute
    alias ServiceRadar.Edge.StreamRoute

    defp uuidv7(seed) do
      bytes = Enum.map(0..15, &rem(seed + &1, 256))

      bytes
      |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
      |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
      |> :erlang.list_to_binary()
    end

    defp slot,
      do: %{network_scope_id: uuidv7(0x40), authenticated_agent_id: "agent-0", spool_id: uuidv7(0x01), sequence: 7}

    # The digest is COMPUTED from the bytes rather than supplied alongside them. The previous
    # version of this test passed a different `record_sha256` while leaving `record_bytes`
    # untouched, so it proved only that the function hashes its argument -- it never exercised
    # the relationship it claimed to, that different record bytes produce a different msg id.
    defp publication(record_bytes \\ "the-canonical-record-bytes", overrides \\ %{}) do
      Map.merge(
        %{
          slot: slot(),
          record_bytes: record_bytes,
          record_sha256: :crypto.hash(:sha256, record_bytes),
          semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
        },
        overrides
      )
    end

    defp durable_route do
      {:ok, route} =
        StreamRoute.resolve(%{
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          network_scope_id: uuidv7(0x40)
        })

      route
    end

    defp ack_body(route, seq \\ 1), do: ~s({"stream":"#{route.expected_stream}","seq":#{seq}})

    defp header(headers, name), do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

    test "derives the canonical transport header set from the route" do
      route = durable_route()
      assert {:ok, headers} = JetStreamPublisher.headers_for(route, publication())

      assert headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               [
                 "Nats-Expected-Stream",
                 "Nats-Msg-Id",
                 "Sr-Edge-Delivery-Id",
                 "Sr-Edge-Transport-Provenance"
               ]

      assert header(headers, "Nats-Expected-Stream") == route.expected_stream
      for {_k, v} <- headers, do: assert(is_binary(v) and v != "")
    end

    test "publishes the record bytes UNCHANGED to the resolved subject" do
      route = durable_route()
      pub = publication()
      with_reply({:ok, %{body: ack_body(route, 3)}})

      assert {:ok, %{seq: 3}} = JetStreamPublisher.publish_record(route, pub, connection: FakeConn)

      assert_received {:requested, subject, payload, _opts}
      assert payload == pub.record_bytes
      assert subject == route.subject
    end

    test "DIFFERENT RECORD BYTES produce a different msg id, so a reused slot cannot collide" do
      route = durable_route()

      {:ok, a} = JetStreamPublisher.headers_for(route, publication("record-one"))
      {:ok, b} = JetStreamPublisher.headers_for(route, publication("record-two"))

      refute header(a, "Nats-Msg-Id") == header(b, "Nats-Msg-Id")

      # The delivery id addresses the SLOT, so the payload does not move it. If it did, a retry
      # of the same slot would look like a new delivery.
      assert header(a, "Sr-Edge-Delivery-Id") == header(b, "Sr-Edge-Delivery-Id")
    end

    test "the same publication derives identically, which makes a replay a duplicate" do
      route = durable_route()

      assert JetStreamPublisher.headers_for(route, publication()) ==
               JetStreamPublisher.headers_for(route, publication())
    end

    test "provenance is stamped with the ROUTE's generation, not a caller's" do
      route = durable_route()
      {:ok, honest} = JetStreamPublisher.headers_for(route, publication())

      {:ok, spoofed} =
        JetStreamPublisher.headers_for(
          route,
          publication("the-canonical-record-bytes", %{route_map_version: 99})
        )

      assert header(honest, "Sr-Edge-Transport-Provenance") ==
               header(spoofed, "Sr-Edge-Transport-Provenance")
    end
  end

  describe "the ack is fenced against the resolved stream" do
    alias ServiceRadar.Edge.StreamRoute

    defp route_and_pub do
      {:ok, route} =
        StreamRoute.resolve(%{
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          network_scope_id: :binary.copy(<<0x11>>, 16)
        })

      bytes = "rec"

      {route,
       %{
         slot: %{
           network_scope_id: uuidv7(0x40),
           authenticated_agent_id: "agent-0",
           spool_id: uuidv7(0x01),
           sequence: 7
         },
         record_bytes: bytes,
         record_sha256: :crypto.hash(:sha256, bytes),
         semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
       }}
    end

    test "an ack naming the expected stream is durable" do
      {route, pub} = route_and_pub()
      with_reply({:ok, %{body: ~s({"stream":"#{route.expected_stream}","seq":5})}})

      assert {:ok, %{seq: 5}} = JetStreamPublisher.publish_record(route, pub, connection: FakeConn)
    end

    test "an ack from ANOTHER stream is a protocol error, never durable success" do
      {route, pub} = route_and_pub()
      # A well-formed PubAck -- just from the wrong stream. Nats-Expected-Stream asks the SERVER
      # to fence this; trusting that alone assumes every broker on the path honours it.
      with_reply({:ok, %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_INTERACTIVE","seq":5})}})

      assert {:error, :protocol} =
               JetStreamPublisher.publish_record(route, pub, connection: FakeConn)

      refute JetStreamPublisher.retryable?(:protocol),
             "retrying reproduces a misroute; it must not be retryable"
    end

    test "a DLQ route only accepts its own stream's ack" do
      {_route, pub} = route_and_pub()
      {:ok, dlq} = StreamRoute.resolve_dlq(:EDGE_RECORD_TRAFFIC_CLASS_BULK, 4)

      with_reply({:ok, %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_BULK","seq":1})}})

      assert {:error, :protocol} =
               JetStreamPublisher.publish_record(dlq, pub, connection: FakeConn)
    end
  end

  describe "refusals never reach the broker" do
    alias ServiceRadar.Edge.StreamRoute

    defp a_route do
      {:ok, r} =
        StreamRoute.resolve(%{
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          network_scope_id: :binary.copy(<<0x22>>, 16)
        })

      r
    end

    defp base_pub do
      %{
        slot: %{
          network_scope_id: uuidv7(0x40),
          authenticated_agent_id: "agent-0",
          spool_id: uuidv7(0x01),
          sequence: 7
        },
        record_bytes: "rec",
        record_sha256: :crypto.hash(:sha256, "rec"),
        semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
      }
    end

    test "MISSING record_bytes returns the documented error tuple rather than raising" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})
      pub = Map.delete(base_pub(), :record_bytes)

      # Previously this raised a KeyError out of a function whose contract says it returns
      # {:error, _}, so a caller's `case` would never see it.
      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(a_route(), pub, connection: FakeConn)

      refute_received {:requested, _, _, _}
    end

    test "non-binary record_bytes is refused the same way" do
      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(
                 a_route(),
                 Map.put(base_pub(), :record_bytes, :not_binary),
                 connection: FakeConn
               )
    end

    test "a malformed slot is a derivation error, never a published record" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      for bad <- [
            %{slot: %{base_pub().slot | sequence: 0}},
            %{slot: %{base_pub().slot | authenticated_agent_id: "not a principal!"}},
            %{slot: %{base_pub().slot | spool_id: <<0::128>>}},
            %{record_sha256: <<1, 2, 3>>},
            %{semantic_envelope_sha256: <<>>}
          ] do
        pub = Map.merge(base_pub(), bad)

        assert {:error, {:derivation, _}} =
                 JetStreamPublisher.publish_record(a_route(), pub, connection: FakeConn),
               "expected #{inspect(Map.keys(bad))} to fail derivation"
      end

      refute_received {:requested, _, _, _}
    end

    test "something that is not a ResolvedRoute is refused" do
      assert {:error, {:derivation, :route}} =
               JetStreamPublisher.publish_record(
                 %{subject: "telemetry.edge-record.v1.bulk.p00"},
                 base_pub(),
                 connection: FakeConn
               )
    end

    test "there is no public raw-publish bypass" do
      refute function_exported?(JetStreamPublisher, :publish, 3)
      refute function_exported?(JetStreamPublisher, :publish, 4)
    end

    test "transport failures stay retryable and are never durable success" do
      with_reply({:error, :timeout})

      assert {:error, :timeout} =
               JetStreamPublisher.publish_record(a_route(), base_pub(), connection: FakeConn)

      with_reply({:error, {:nats_not_connected, :down}})

      assert {:error, :capacity} =
               JetStreamPublisher.publish_record(a_route(), base_pub(), connection: FakeConn)
    end
  end
end
