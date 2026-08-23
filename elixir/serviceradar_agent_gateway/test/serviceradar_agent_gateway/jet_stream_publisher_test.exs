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

  describe "PubAck sequence bounds" do
    test "a non-positive or out-of-range sequence is a protocol error, never durable" do
      # `is_integer/1` alone accepted these. A malformed ack reported as durable resolves a
      # source sequence that was never accepted.
      for bad <- [-1, 0, -9_999, 0x1_0000_0000_0000_0000] do
        assert {:error, :protocol} =
                 JetStreamPublisher.parse_ack(~s({"stream":"S","seq":#{bad}})),
               "seq #{bad} was accepted"
      end
    end

    test "the boundaries themselves: 1 and u64 max are valid" do
      assert {:ok, %{seq: 1}} = JetStreamPublisher.parse_ack(~s({"stream":"S","seq":1}))

      assert {:ok, %{seq: 18_446_744_073_709_551_615}} =
               JetStreamPublisher.parse_ack(~s({"stream":"S","seq":18446744073709551615}))
    end
  end

  describe "publish_record/2 derives its own route" do
    import Bitwise

    defp uuidv7(seed) do
      bytes = Enum.map(0..15, &rem(seed + &1, 256))

      bytes
      |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
      |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
      |> :erlang.list_to_binary()
    end

    defp publication(overrides \\ %{}) do
      bytes = Map.get(overrides, :record_bytes, "the-canonical-record-bytes")

      Map.merge(
        %{
          slot: %{
            network_scope_id: uuidv7(0x40),
            authenticated_agent_id: "agent-0",
            spool_id: uuidv7(0x01),
            sequence: 7
          },
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          partition_rule: :network_scope_v1,
          record_bytes: bytes,
          record_sha256: :crypto.hash(:sha256, bytes),
          semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
        },
        overrides
      )
    end

    defp header(headers, name), do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

    test "there is NO api that accepts a route, so route and publication cannot disagree" do
      # The previous shape took (route, publication) and a test proved the two could describe
      # different records -- a route resolved for one scope publishing a slot from another.
      # ensure_loaded! first: function_exported?/3 answers false for a module that simply has
      # not been loaded, which would make every assertion here pass for the wrong reason.
      {:module, _} = Code.ensure_loaded(JetStreamPublisher)

      refute function_exported?(JetStreamPublisher, :publish_record, 3)
      refute function_exported?(JetStreamPublisher, :headers_for, 2)
      assert function_exported?(JetStreamPublisher, :publish_record, 2)
    end

    test "the subject follows the slot's scope: changing the scope moves the record" do
      {:ok, a} = JetStreamPublisher.plan(publication())

      other_slot = %{publication().slot | network_scope_id: uuidv7(0x70)}
      {:ok, b} = JetStreamPublisher.plan(publication(%{slot: other_slot}))

      refute a.route.subject == b.route.subject,
             "the route ignored the authenticated scope, so it is not bound to the publication"
    end

    test "publishes the record bytes UNCHANGED to the derived subject" do
      {:ok, planned} = JetStreamPublisher.plan(publication())
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":3})}})

      assert {:ok, %{seq: 3}} =
               JetStreamPublisher.publish_record(publication(), connection: FakeConn)

      assert_received {:requested, subject, payload, _opts}
      assert payload == publication().record_bytes
      assert subject == planned.route.subject
      assert subject =~ ~r"^telemetry\.edge-record\.v1\.bulk\.p\d{2}$"
    end

    test "an unknown partition rule refuses before any publish" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      assert {:error, {:derivation, :unknown_partition_rule}} =
               JetStreamPublisher.publish_record(
                 publication(%{partition_rule: :execution_v1}),
                 connection: FakeConn
               )

      refute_received {:requested, _, _, _}
    end

    test "different record bytes produce a different msg id" do
      {:ok, a} = JetStreamPublisher.plan(publication(%{record_bytes: "record-one"}))
      {:ok, b} = JetStreamPublisher.plan(publication(%{record_bytes: "record-two"}))

      refute header(a.headers, "Nats-Msg-Id") == header(b.headers, "Nats-Msg-Id")
      assert header(a.headers, "Sr-Edge-Delivery-Id") == header(b.headers, "Sr-Edge-Delivery-Id")
    end
  end

  describe "the header wiring is bound to the ABI vectors" do
    # Task 3.3 requires the exact vector assertion to cover the PUBLISHER's header wiring, not
    # merely the identity functions underneath. Asserting only that headers are non-empty and
    # change relationally leaves `Nats-Msg-Id` and the provenance swappable while staying green.
    @testdata Path.expand("../../../../proto/edge/v1/testdata", __DIR__)

    defp fixture_path(name) do
      direct = Path.join(@testdata, name)

      cond do
        File.exists?(direct) ->
          {:ok, direct}

        dir = System.get_env("TEST_SRCDIR") ->
          [System.get_env("TEST_WORKSPACE"), "_main"]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata", name]))
          |> Enum.find(&File.exists?/1)
          |> case do
            nil -> :error
            p -> {:ok, p}
          end

        true ->
          :error
      end
    end

    defp load(name) do
      case fixture_path(name) do
        {:ok, path} -> File.read!(path)
        :error -> raise "shared fixture #{name} not found under #{@testdata} or TEST_SRCDIR"
      end
    end

    # The EXACT construction the shared vectors were cut with -- it embeds a fixed millisecond
    # prefix rather than sequential bytes. Reproducing it is the whole point: a nearby-but-
    # different spool id yields a different msg id, which is how this test first failed.
    @fixed_millis 1_784_000_000_000

    defp vector_uuidv7(seed) do
      import Bitwise

      <<ms6::binary-6, _::binary-2>> = <<@fixed_millis <<< 16::big-64>>
      rest = for i <- 6..15, into: <<>>, do: <<seed + i::8>>
      <<b0::binary-6, b6, b7, b8, b9::binary-7>> = ms6 <> rest
      b0 <> <<(b6 &&& 0x0F) ||| 0x70, b7, (b8 &&& 0x3F) ||| 0x80>> <> b9
    end

    test "each header carries the exact ABI vector value for its own name" do
      record_bin = load("record.bin")
      record = Serviceradar.Edge.V1.EdgeRecordV1.decode(record_bin)

      # The same slot the shared golden vectors were cut against.
      slot = %{
        network_scope_id: record.network_scope_id,
        authenticated_agent_id: record.producer_context.origin_principal_id,
        spool_id: vector_uuidv7(0x01),
        sequence: 1
      }

      publication = %{
        slot: slot,
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: record_bin,
        record_sha256: :crypto.hash(:sha256, record_bin),
        semantic_envelope_sha256: record.semantic_envelope_sha256
      }

      assert {:ok, planned} = JetStreamPublisher.plan(publication)

      expected_msg_id = load("nats_msg_id.txt")
      expected_delivery_id = load("delivery_id.txt")

      # NOT VACUOUS, and this is the point: the value is pinned to the header NAME. Swapping
      # Nats-Msg-Id with the provenance, or with the delivery id, fails here.
      assert header(planned.headers, "Nats-Msg-Id") == expected_msg_id
      assert header(planned.headers, "Sr-Edge-Delivery-Id") == expected_delivery_id

      # The two are distinct values, so the assertions above cannot both pass by coincidence.
      refute expected_msg_id == expected_delivery_id

      # Provenance is a real, distinct value on its own header.
      provenance = header(planned.headers, "Sr-Edge-Transport-Provenance")
      assert is_binary(provenance) and provenance != ""
      refute provenance in [expected_msg_id, expected_delivery_id]

      assert header(planned.headers, "Nats-Expected-Stream") == planned.route.expected_stream
    end
  end

  describe "a wrong-stream ack withholds progress rather than DLQ-ing" do
    defp planned_pub do
      pub = %{
        slot: %{
          network_scope_id: uuidv7(0x40),
          authenticated_agent_id: "agent-0",
          spool_id: uuidv7(0x01),
          sequence: 7
        },
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: "rec",
        record_sha256: :crypto.hash(:sha256, "rec"),
        semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
      }

      {:ok, planned} = JetStreamPublisher.plan(pub)
      {pub, planned}
    end

    test "an ack naming the expected stream is durable" do
      {pub, planned} = planned_pub()
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":5})}})

      assert {:ok, %{seq: 5}} = JetStreamPublisher.publish_record(pub, connection: FakeConn)
    end

    test "an ack from ANOTHER stream is :misrouted, and :misrouted WITHHOLDS progress" do
      {pub, _planned} = planned_pub()
      with_reply({:ok, %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_INTERACTIVE","seq":5})}})

      assert {:error, :misrouted} = JetStreamPublisher.publish_record(pub, connection: FakeConn)

      # THE POINT: a wrong-stream ack is not authoritative acceptance. Classifying it terminal
      # would DLQ a record that may already be durable elsewhere and resolve a sequence that was
      # never accepted. Progress must stay unresolved instead.
      assert JetStreamPublisher.retryable?(:misrouted),
             "a misrouted ack must withhold source progress, not send the record to the DLQ"
    end

    test "genuinely terminal classes remain terminal" do
      refute JetStreamPublisher.retryable?(:permanent)
      refute JetStreamPublisher.retryable?(:protocol)
      assert JetStreamPublisher.retryable?(:capacity)
      assert JetStreamPublisher.retryable?(:timeout)
    end
  end

  describe "the DLQ route is derived from the source" do
    test "publish_dlq lands on the source's partition, in the source's class" do
      {pub, planned} = planned_pub()

      {:ok, dlq_route} =
        ServiceRadar.Edge.StreamRoute.resolve_dlq(planned.route, %{
          route_profile: pub.route_profile,
          traffic_class: pub.traffic_class,
          partition_rule: pub.partition_rule,
          partition_coordinates: %{
            network_scope_id: pub.slot.network_scope_id,
            authenticated_agent_id: pub.slot.authenticated_agent_id,
            spool_id: pub.slot.spool_id
          }
        })

      with_reply({:ok, %{body: ~s({"stream":"#{dlq_route.expected_stream}","seq":2})}})

      assert {:ok, %{seq: 2}} = JetStreamPublisher.publish_dlq(pub, connection: FakeConn)

      assert_received {:requested, subject, _payload, _opts}
      assert subject == dlq_route.subject
      assert subject =~ "telemetry.edge-record-dlq.v1.bulk."
      assert dlq_route.partition == planned.route.partition
    end

    test "the DLQ publish is fenced against the DLQ stream, not the data stream" do
      {pub, planned} = planned_pub()
      # A perfectly good ack -- from the DATA stream.
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":2})}})

      assert {:error, :misrouted} = JetStreamPublisher.publish_dlq(pub, connection: FakeConn)
    end
  end

  describe "refusals never reach the broker" do
    defp base_pub do
      %{
        slot: %{
          network_scope_id: uuidv7(0x40),
          authenticated_agent_id: "agent-0",
          spool_id: uuidv7(0x01),
          sequence: 7
        },
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: "rec",
        record_sha256: :crypto.hash(:sha256, "rec"),
        semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
      }
    end

    test "MISSING record_bytes returns the documented error tuple rather than raising" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(
                 Map.delete(base_pub(), :record_bytes),
                 connection: FakeConn
               )

      refute_received {:requested, _, _, _}
    end

    test "non-binary record_bytes is refused the same way" do
      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(
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
        assert {:error, {:derivation, _}} =
                 JetStreamPublisher.publish_record(
                   Map.merge(base_pub(), bad),
                   connection: FakeConn
                 ),
               "expected #{inspect(Map.keys(bad))} to fail derivation"
      end

      refute_received {:requested, _, _, _}
    end

    test "there is no public raw-publish bypass" do
      refute function_exported?(JetStreamPublisher, :publish, 3)
      refute function_exported?(JetStreamPublisher, :publish, 4)
    end

    test "transport failures stay retryable and are never durable success" do
      with_reply({:error, :timeout})

      assert {:error, :timeout} =
               JetStreamPublisher.publish_record(base_pub(), connection: FakeConn)

      with_reply({:error, {:nats_not_connected, :down}})

      assert {:error, :capacity} =
               JetStreamPublisher.publish_record(base_pub(), connection: FakeConn)
    end
  end
end
