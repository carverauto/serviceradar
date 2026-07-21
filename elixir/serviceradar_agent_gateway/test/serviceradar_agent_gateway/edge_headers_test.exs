defmodule ServiceRadarAgentGateway.EdgeHeadersTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias ServiceRadarAgentGateway.EdgeDigest
  alias ServiceRadarAgentGateway.EdgeHeaders

  defp identity, do: %{network_scope_id: "scope-id-16bytes", agent_id: "agent-id-16bytes"}

  defp frame do
    %EdgeResultFrame{
      spool_id: "spool-id-16bytes",
      sequence: 42,
      event_id: "event-id-16bytes",
      payload_kind: :EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
      schema_version: 1,
      payload_sha256: "0123456789abcdef0123456789abcdef",
      execution_id: "exec-id-16bytes!",
      execution_shard: 3,
      assignment_epoch: 5,
      network_scope_id: "scope-id-16bytes",
      traffic_class: :EDGE_RESULT_TRAFFIC_CLASS_BULK,
      authorization_kind: :EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT,
      projected_row_count: 10,
      cost_model_version: 2,
      payload: "inner"
    }
  end

  test "stamps the JetStream ids and the canonical Sr-Edge envelope" do
    headers = EdgeHeaders.build(identity(), frame(), "EDGE_SWEEP_BULK_V1")
    map = Map.new(headers)

    assert map["Nats-Msg-Id"] == EdgeDigest.msg_id(identity(), frame())
    assert map["Nats-Expected-Stream"] == "EDGE_SWEEP_BULK_V1"

    # The semantic digest is the DB idempotency key, stamped separately from the
    # dedup id and placement.
    assert map["Sr-Edge-Semantic-Digest"] ==
             Base.encode16(EdgeDigest.semantic_digest(frame()), case: :lower)

    # Enums are decimal strings of the protobuf integer value.
    assert map["Sr-Edge-Payload-Kind"] == "1"
    assert map["Sr-Edge-Traffic-Class"] == "1"
    assert map["Sr-Edge-Authorization-Kind"] == "1"

    # Counts pass through as decimal strings.
    assert map["Sr-Edge-Sequence"] == "42"
    assert map["Sr-Edge-Execution-Shard"] == "3"
    assert map["Sr-Edge-Assignment-Epoch"] == "5"
    assert map["Sr-Edge-Projected-Row-Count"] == "10"

    # Binary ids are base64url (decode round-trips).
    assert Base.url_decode64!(map["Sr-Edge-Event-Id"], padding: false) == "event-id-16bytes"
    assert Base.url_decode64!(map["Sr-Edge-Spool-Id"], padding: false) == "spool-id-16bytes"
    assert Base.url_decode64!(map["Sr-Edge-Network-Scope-Id"], padding: false) == "scope-id-16bytes"

    # Digest-shaped fields are hex.
    assert map["Sr-Edge-Payload-Sha256"] ==
             Base.encode16("0123456789abcdef0123456789abcdef", case: :lower)
  end

  test "nil binary/count fields degrade to empty/zero, never crash" do
    headers = EdgeHeaders.build(identity(), %EdgeResultFrame{}, "EDGE_SWEEP_BULK_V1")
    map = Map.new(headers)
    assert map["Sr-Edge-Event-Id"] == ""
    assert map["Sr-Edge-Sequence"] == "0"
    assert map["Sr-Edge-Payload-Kind"] == "0"
  end
end
