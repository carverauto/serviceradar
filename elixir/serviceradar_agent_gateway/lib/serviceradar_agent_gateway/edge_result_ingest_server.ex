defmodule ServiceRadarAgentGateway.EdgeResultIngestServer do
  @moduledoc """
  gRPC server for `EdgeResultIngest` -- the durable edge result relay
  (unify-sweep-results-proto tasks 3.1, 3.6). One bidirectional stream is one
  delivery lane: the agent sends a lane-open handshake then a run of result
  frames; the gateway replies with the handshake ack then cumulative
  dispositions.

  This module is thin transport glue over the tested `EdgeResultRelay` session
  processor: it derives the trusted identity from the mTLS certificate, drives the
  incoming message stream through the relay, and sends each produced server
  message. gRPC success is never treated as durable -- durability is the
  JetStream PubAck the relay observes -- and the lane is stateless across
  restarts (state lives only for the connection's lifetime).
  """

  use GRPC.Server, service: Serviceradar.Edge.V1.EdgeResultIngest.Service

  alias Serviceradar.Edge.V1.EdgeResultServerMessage
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.EdgeResultRelay
  alias ServiceRadarAgentGateway.MediaIdentity

  require Logger

  @spec stream(Enumerable.t(), GRPC.Server.Stream.t()) :: GRPC.Server.Stream.t()
  def stream(request_stream, stream) do
    session = EdgeResultRelay.new(trusted_identity(stream))

    Enum.reduce(request_stream, session, fn message, session ->
      handle_message(message.payload, session, stream)
    end)

    stream
  end

  defp handle_message({:lane_open, lane_open}, session, stream) do
    case EdgeResultRelay.open(session, lane_open) do
      {:ok, ack, session} ->
        send_reply(stream, {:lane_open_ack, ack})
        session

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "edge lane open rejected: #{reason}"
    end
  end

  defp handle_message({:frame, frame}, session, stream) do
    case EdgeResultRelay.frame(session, frame) do
      {:ok, :withhold, session} ->
        # No durable outcome yet; withhold the disposition so the agent keeps the
        # frame spooled and retries.
        session

      {:ok, ack, session} ->
        send_reply(stream, {:ack, ack})
        session

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "edge frame rejected: #{reason}"
    end
  end

  defp handle_message(_other, session, _stream), do: session

  defp send_reply(stream, payload) do
    GRPC.Server.send_reply(stream, %EdgeResultServerMessage{payload: payload})
  end

  # Derive the trusted (certificate-derived) identity used to anchor the
  # JetStream Nats-Msg-Id namespace. The network scope is taken from the cert
  # partition binding; full §3.2 network-scope resolution is a follow-up.
  defp trusted_identity(stream) do
    identity =
      MediaIdentity.extract_identity_from_stream(stream, ComponentIdentityResolver, "EdgeResultIngest")

    %{
      network_scope_id: to_string(Map.get(identity, :partition_id) || ""),
      agent_id: to_string(Map.get(identity, :component_id) || "")
    }
  end
end
