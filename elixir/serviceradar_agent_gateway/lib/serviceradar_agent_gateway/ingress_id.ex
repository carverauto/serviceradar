defmodule ServiceRadarAgentGateway.IngressId do
  @moduledoc """
  Gateway ingress identifiers for leaf-compatible telemetry ordering.

  The identifier is UUIDv8-shaped and k-sortable by Unix microsecond timestamp:
  60 timestamp bits, UUID version/variant bits, then 62 random bits. It is not
  a general UUID library; it is the edge-ingress ordering key used by gateway
  publishers.
  """

  import Bitwise

  @max_timestamp (1 <<< 60) - 1
  @max_random (1 <<< 62) - 1

  @spec new() :: String.t()
  def new, do: new(System.system_time(:nanosecond))

  @spec new(integer()) :: String.t()
  def new(timestamp_unix_nano) when is_integer(timestamp_unix_nano) do
    timestamp_micros =
      timestamp_unix_nano
      |> div(1_000)
      |> Bitwise.band(@max_timestamp)

    <<time_high::48, time_low::12>> = <<timestamp_micros::60>>
    random = random_62_bits()

    format_uuid(<<time_high::48, 8::4, time_low::12, 2::2, random::62>>)
  end

  @spec headers(map()) :: [{String.t(), String.t()}]
  def headers(context) when is_map(context) do
    ingress_time = Map.get(context, :ingress_time_unix_nano, System.system_time(:nanosecond))
    ingress_id = Map.get(context, :ingress_id) || new(ingress_time)
    message_id = context[:nats_msg_id] || context[:message_id] || context[:event_id] || ingress_id

    [
      {"Sr-Ingress-Id", ingress_id},
      {"Sr-Ingress-Time-Unix-Nano", Integer.to_string(ingress_time)},
      # JetStream message-dedup key (fj #3788, REC4). When a publisher supplies a
      # stable id (nats_msg_id/message_id/event_id) we use it so an exact
      # redelivery dedups; otherwise we fall back to the per-ingress ingress_id.
      # Either way this only collapses an EXACT redelivery within a stream's
      # duplicate_window — never two distinct measurements.
      {"Nats-Msg-Id", to_string(message_id)}
    ]
    |> maybe_header("Sr-Agent-Id", context[:agent_id])
    |> maybe_header("Sr-Gateway-Id", context[:gateway_id])
    |> maybe_header("Sr-Partition", context[:partition_id] || context[:partition])
    |> maybe_header("Sr-Ingest-Identity", context[:ingest_identity])
  end

  @spec put_payload_metadata(map(), map()) :: map()
  def put_payload_metadata(payload, context) when is_map(payload) and is_map(context) do
    ingress_time = Map.get(context, :ingress_time_unix_nano, System.system_time(:nanosecond))
    ingress_id = Map.get(context, :ingress_id) || new(ingress_time)

    payload
    |> Map.put("ingress_id", ingress_id)
    |> Map.put("ingress_timestamp_unix_nano", ingress_time)
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: headers ++ [{name, to_string(value)}]

  defp random_62_bits do
    <<value::64>> = :crypto.strong_rand_bytes(8)
    Bitwise.band(value, @max_random)
  end

  defp format_uuid(<<uuid::128>>) do
    hex = Base.encode16(<<uuid::128>>, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> =
      hex

    Enum.join([a, b, c, d, e], "-")
  end
end
