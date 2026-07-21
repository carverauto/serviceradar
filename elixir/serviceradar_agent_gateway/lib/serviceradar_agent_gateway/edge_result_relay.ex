defmodule ServiceRadarAgentGateway.EdgeResultRelay do
  @moduledoc """
  Per-lane session processor for the durable edge result relay
  (unify-sweep-results-proto tasks 3.3-3.6). It is the transport-agnostic core of
  the `EdgeResultIngest` gRPC handler: given the trusted mTLS identity and a
  decoded client message, it produces the server messages to send and the next
  session state, using `EdgeRoute`/`EdgeDigest` for routing, `JetStreamPublisher`
  for durable publish (injectable), and `EdgePrefix` for the contiguous resolved
  watermark.

  Durability rule (task 3.5/3.6): the resolved prefix advances only after a
  primary-stream PubAck (accepted) or an audit/DLQ PubAck (permanent rejection).
  A retryable publish failure withholds -- no disposition, no prefix advance -- so
  the agent keeps the frame spooled. gRPC success is never treated as durable and
  this lane never buffers to an out-of-band handoff.
  """

  alias Serviceradar.Edge.V1.EdgeResultAck
  alias Serviceradar.Edge.V1.EdgeResultDisposition
  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias Serviceradar.Edge.V1.EdgeResultLaneOpen
  alias Serviceradar.Edge.V1.EdgeResultLaneOpenAck
  alias ServiceRadarAgentGateway.EdgeDigest
  alias ServiceRadarAgentGateway.EdgePrefix
  alias ServiceRadarAgentGateway.EdgeRoute
  alias ServiceRadarAgentGateway.JetStreamPublisher

  @default_byte_credits 8 * 1024 * 1024
  @default_frame_credits 256

  defstruct [
    :identity,
    :spool_id,
    :session_nonce,
    :prefix,
    :publisher,
    established?: false,
    granted_byte_credits: @default_byte_credits,
    granted_frame_credits: @default_frame_credits
  ]

  @type t :: %__MODULE__{}

  @doc "New session for a trusted identity `%{network_scope_id, agent_id}`."
  @spec new(map(), keyword()) :: t()
  def new(identity, opts \\ []) do
    %__MODULE__{
      identity: identity,
      publisher: Keyword.get(opts, :publisher, JetStreamPublisher),
      granted_byte_credits: Keyword.get(opts, :byte_credits, @default_byte_credits),
      granted_frame_credits: Keyword.get(opts, :frame_credits, @default_frame_credits)
    }
  end

  @doc "Handle the opening handshake; returns the lane-open ack and established state."
  @spec open(t(), EdgeResultLaneOpen.t()) :: {:ok, EdgeResultLaneOpenAck.t(), t()} | {:error, atom()}
  def open(%__MODULE__{established?: true}, _), do: {:error, :already_established}

  def open(%__MODULE__{} = s, %EdgeResultLaneOpen{} = lo) do
    cond do
      empty?(lo.spool_id) ->
        {:error, :missing_spool_id}

      empty?(lo.session_nonce) ->
        {:error, :missing_nonce}

      true ->
        first = if lo.first_unresolved_sequence in [nil, 0], do: 1, else: lo.first_unresolved_sequence

        s = %{
          s
          | spool_id: lo.spool_id,
            session_nonce: lo.session_nonce,
            established?: true,
            prefix: EdgePrefix.new(first)
        }

        ack = %EdgeResultLaneOpenAck{
          spool_id: lo.spool_id,
          session_nonce: lo.session_nonce,
          granted_byte_credits: s.granted_byte_credits,
          granted_frame_credits: s.granted_frame_credits
        }

        {:ok, ack, s}
    end
  end

  @doc """
  Process one frame. Returns `{:ok, %EdgeResultAck{}, state}` when the frame
  reaches a durable outcome, `{:ok, :withhold, state}` when a retryable failure
  means the agent should keep it spooled, or `{:error, reason}` on a binding
  violation.
  """
  @spec frame(t(), EdgeResultFrame.t()) :: {:ok, EdgeResultAck.t() | :withhold, t()} | {:error, atom()}
  def frame(%__MODULE__{established?: false}, _), do: {:error, :not_established}

  def frame(%__MODULE__{} = s, %EdgeResultFrame{} = f) do
    cond do
      f.spool_id != s.spool_id -> {:error, :spool_mismatch}
      empty_seq?(f.sequence) -> {:error, :missing_sequence}
      true -> publish_frame(s, f)
    end
  end

  # --- internals ---

  defp publish_frame(s, f) do
    lane = EdgeRoute.lane_for(f.payload_kind, f.traffic_class)
    partition = EdgeRoute.partition(f.network_scope_id || "")
    msg_id = EdgeDigest.msg_id(s.identity, f)
    payload = f.payload || ""

    subject = EdgeRoute.data_subject(lane, partition)
    headers = [{"Nats-Msg-Id", msg_id}, {"Nats-Expected-Stream", EdgeRoute.physical_stream(lane)}]

    # Publish the inner protobuf bytes verbatim (task 3.4: no domain decode/re-encode).
    case s.publisher.publish(subject, payload, headers) do
      {:ok, _pub_ack} ->
        resolve(s, f.sequence, :accepted)

      {:error, class} ->
        if JetStreamPublisher.retryable?(class) do
          {:ok, :withhold, s}
        else
          dead_letter(s, f, lane, partition, msg_id, payload, class)
        end
    end
  end

  defp dead_letter(s, f, lane, partition, msg_id, payload, class) do
    subject = EdgeRoute.dlq_subject(lane, partition)

    headers = [
      {"Nats-Msg-Id", msg_id},
      {"Nats-Expected-Stream", EdgeRoute.physical_dlq_stream(lane)}
    ]

    case s.publisher.publish(subject, payload, headers) do
      {:ok, _pub_ack} -> resolve(s, f.sequence, :rejected, to_string(class))
      # DLQ itself is unavailable: withhold and retry rather than lose the frame.
      {:error, _} -> {:ok, :withhold, s}
    end
  end

  defp resolve(s, sequence, kind, code \\ "") do
    case EdgePrefix.record(s.prefix, sequence, kind) do
      {:ok, prefix} ->
        s = %{s | prefix: prefix}
        {:ok, build_ack(s, sequence, kind, code), s}

      # A record conflict/out-of-range is not a durable win; withhold this frame.
      {:error, _reason} ->
        {:ok, :withhold, s}
    end
  end

  defp build_ack(s, sequence, kind, code) do
    %EdgeResultAck{
      spool_id: s.spool_id,
      session_nonce: s.session_nonce,
      resolved_through_sequence: EdgePrefix.resolved_through(s.prefix),
      dispositions: [
        %EdgeResultDisposition{sequence: sequence, kind: disposition_kind(kind), rejection_code: code}
      ]
    }
  end

  defp disposition_kind(:accepted), do: :EDGE_RESULT_DISPOSITION_KIND_ACCEPTED
  defp disposition_kind(:rejected), do: :EDGE_RESULT_DISPOSITION_KIND_REJECTED

  defp empty?(nil), do: true
  defp empty?(b) when is_binary(b), do: byte_size(b) == 0
  defp empty?(_), do: true

  defp empty_seq?(nil), do: true
  defp empty_seq?(0), do: true
  defp empty_seq?(n) when is_integer(n) and n > 0, do: false
  defp empty_seq?(_), do: true
end
