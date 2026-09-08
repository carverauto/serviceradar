defmodule ServiceRadarAgentGateway.IngressIdTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.IngressId

  @uuidv8_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "generates UUIDv8-shaped ingress ids" do
    assert IngressId.new(1_765_500_000_000_000_000) =~ @uuidv8_pattern
  end

  test "orders lexically by timestamp prefix" do
    older = IngressId.new(1_765_500_000_000_000_000)
    newer = IngressId.new(1_765_500_001_000_000_000)

    assert older < newer
  end

  test "builds ingress attribution headers" do
    headers =
      IngressId.headers(%{
        ingress_id: "00000645-50de-8e80-8000-000000000001",
        ingress_time_unix_nano: 1_765_500_000_000_000_000,
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "prod-east",
        ingest_identity: "agent:agent-1"
      })

    assert headers == [
             {"Sr-Ingress-Id", "00000645-50de-8e80-8000-000000000001"},
             {"Sr-Ingress-Time-Unix-Nano", "1765500000000000000"},
             {"Nats-Msg-Id", "00000645-50de-8e80-8000-000000000001"},
             {"Sr-Agent-Id", "agent-1"},
             {"Sr-Gateway-Id", "gateway-1"},
             {"Sr-Partition", "prod-east"},
             {"Sr-Ingest-Identity", "agent:agent-1"}
           ]
  end

  test "uses stable event id as JetStream message id when available" do
    headers =
      IngressId.headers(%{
        ingress_id: "00000645-50de-8e80-8000-000000000001",
        ingress_time_unix_nano: 1_765_500_000_000_000_000,
        event_id: "plugin-event-1"
      })

    assert {"Nats-Msg-Id", "plugin-event-1"} in headers
  end

  test "stamps payload metadata" do
    payload =
      IngressId.put_payload_metadata(%{"schema" => "example.v1"}, %{
        ingress_id: "00000645-50de-8e80-8000-000000000001",
        ingress_time_unix_nano: 1_765_500_000_000_000_000
      })

    assert payload == %{
             "schema" => "example.v1",
             "ingress_id" => "00000645-50de-8e80-8000-000000000001",
             "ingress_timestamp_unix_nano" => 1_765_500_000_000_000_000
           }
  end
end
