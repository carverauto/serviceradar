defmodule ServiceRadar.Edge.LaneValidate do
  @moduledoc """
  Structural admission of both halves of the edge lane handshake.

  Mirrors Go's `ValidateLaneOpen` and `ValidateLaneOpenAck`. The return half
  validates the request again, requires spool/nonce/route/class echoes, and bounds
  each granted credit dimension by its request. These decoded APIs do not claim
  live ingress attachment; raw callers must first apply the wire boundary.
  """

  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck

  @max_byte_credits 1_073_741_824
  @max_frame_credits 1_048_576
  @max_sequence 18_446_744_073_709_551_615

  @spec open(term()) :: :ok | {:error, term()}
  def open(%EdgeRecordLaneOpen{} = request) do
    with :ok <- shape(request, %EdgeRecordLaneOpen{}),
         :ok <- SemanticValidate.validate_lane_open(request) do
      cond do
        not PlanValidate.uuidv7?(request.spool_id) ->
          {:error, :identity}

        request.sequence_base !== 1 or
            not integer_in?(request.first_unresolved_sequence, 1, @max_sequence) ->
          {:error, :sequence_base}

        not nonce?(request.session_nonce) ->
          {:error, :nonce}

        not integer_in?(request.requested_byte_credits, 1, @max_byte_credits) or
            not integer_in?(request.requested_frame_credits, 1, @max_frame_credits) ->
          {:error, :credits}

        true ->
          :ok
      end
    end
  end

  def open(_), do: {:error, :shape}

  @spec open_ack(term(), term()) :: :ok | {:error, term()}
  def open_ack(%EdgeRecordLaneOpenAck{} = ack, request) do
    with :ok <- shape(ack, %EdgeRecordLaneOpenAck{}),
         :ok <- open(request) do
      cond do
        ack.spool_id != request.spool_id or ack.session_nonce != request.session_nonce ->
          {:error, :binding}

        ack.route_profile != request.route_profile or ack.traffic_class != request.traffic_class ->
          {:error, :session}

        not integer_in?(ack.granted_byte_credits, 1, request.requested_byte_credits) or
            not integer_in?(ack.granted_frame_credits, 1, request.requested_frame_credits) ->
          {:error, :credits}

        true ->
          :ok
      end
    end
  end

  def open_ack(_, _), do: {:error, :shape}

  # Every value field is checked by the semantic rules above. This precondition
  # prevents forged structs with missing/extra fields from bypassing those reads.
  defp shape(message, default) do
    cond do
      MapSet.new(Map.keys(message)) != MapSet.new(Map.keys(default)) -> {:error, :shape}
      message.__unknown_fields__ != [] -> {:error, :unknown_fields}
      true -> :ok
    end
  end

  defp nonce?(value) when is_binary(value), do: byte_size(value) in 16..64
  defp nonce?(_), do: false
  defp integer_in?(value, first, last), do: is_integer(value) and value >= first and value <= last
end
