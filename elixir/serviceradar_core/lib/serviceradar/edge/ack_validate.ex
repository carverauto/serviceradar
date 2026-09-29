defmodule ServiceRadar.Edge.AckValidate do
  @moduledoc """
  Complete raw delivery-ACK admission, mirroring Go's `DecodeAck`/`ValidateAck`.

  `validate_bytes/3` applies finite raw bytes before decode, then disposition count,
  canonical bytes and cumulative acknowledgement semantics. Budget keys are
  `:raw_bytes`, `:dispositions`, `:canonical_bytes`; absent or non-positive values
  select finite defaults, never disable a gate. Default values are implementation
  policy, not immutable ABI constants.

  Session state is supplied by the caller as a map with binary `:spool_id` and
  `:nonce`, uint64 `:resolved_through` and `:highest_sent`, and a `:sent_events` map
  from sequence to the event bytes actually sent. This validator does not own or
  mutate sender state. It returns the validated decoded ACK.
  """

  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.ResolvedPrefix
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias ServiceRadar.Edge.WireDecode

  @defaults %{raw_bytes: 262_144, dispositions: 4096, canonical_bytes: 262_144}
  @max_limit 9_223_372_036_854_775_807
  @max_sequence 18_446_744_073_709_551_615
  @rejections [
    :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT,
    :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
  ]

  @spec validate_bytes(term(), term(), map()) :: {:ok, EdgeDeliveryAckV1.t()} | {:error, term()}
  def validate_bytes(raw, session, budgets \\ %{}) do
    with {:ok, limits} <- limits(budgets),
         {:ok, ack} <- decode(raw, limits.raw_bytes),
         :ok <- validate(ack, session, limits) do
      {:ok, ack}
    end
  end

  defp limits(budgets) when is_map(budgets) do
    if Map.keys(budgets) -- Map.keys(@defaults) == [] do
      Enum.reduce_while(@defaults, {:ok, %{}}, fn {key, default}, {:ok, acc} ->
        case Map.get(budgets, key, default) do
          n when is_integer(n) and n <= 0 -> {:cont, {:ok, Map.put(acc, key, default)}}
          n when is_integer(n) and n <= @max_limit -> {:cont, {:ok, Map.put(acc, key, n)}}
          _ -> {:halt, {:error, :limits}}
        end
      end)
    else
      {:error, :limits}
    end
  end

  defp limits(_), do: {:error, :limits}

  defp decode(raw, limit) do
    case WireDecode.decode_ack(raw, limit) do
      {:ok, ack} -> {:ok, ack}
      {:error, reason} -> {:error, {:wire, reason}}
    end
  end

  defp validate(ack, session, limits) do
    with :ok <- session_shape(session),
         :ok <- binding_and_window(ack, session),
         {:ok, count} <- count(ack.dispositions, limits.dispositions),
         :ok <- canonical_bytes(ack, limits.canonical_bytes),
         :ok <- SemanticValidate.validate_message(ack),
         :ok <- sequence_room(count, session),
         {:ok, resolved} <- dispositions(ack.dispositions, session) do
      if ack.resolved_through_sequence == session.resolved_through + resolved,
        do: :ok,
        else: {:error, :resolved_prefix}
    end
  end

  defp session_shape(%{
         spool_id: spool,
         nonce: nonce,
         resolved_through: resolved,
         highest_sent: highest,
         sent_events: sent
       })
       when is_binary(spool) and is_binary(nonce) and is_integer(resolved) and resolved >= 0 and
              resolved <= @max_sequence and
              is_integer(highest) and highest >= 0 and highest <= @max_sequence and is_map(sent),
       do: :ok

  defp session_shape(_), do: {:error, :session}

  defp binding_and_window(ack, session) do
    cond do
      ack.spool_id != session.spool_id or ack.session_nonce != session.nonce ->
        {:error, :binding}

      ack.resolved_through_sequence < session.resolved_through or
          ack.resolved_through_sequence > session.highest_sent ->
        {:error, :window}

      true ->
        :ok
    end
  end

  defp count(dispositions, limit) do
    case BoundedList.count_at_most(dispositions, limit) do
      {:ok, count} -> {:ok, count}
      _ -> {:error, :count}
    end
  end

  defp canonical_bytes(ack, limit) do
    if byte_size(EdgeDeliveryAckV1.encode(ack)) <= limit,
      do: :ok,
      else: {:error, :canonical_bytes}
  end

  defp sequence_room(count, session) do
    if session.highest_sent >= session.resolved_through and
         count <= session.highest_sent - session.resolved_through,
       do: :ok,
       else: {:error, :sequence_room}
  end

  defp dispositions(items, session) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0, false}, fn {d, index}, {:ok, resolved, retryable_tail} ->
      resolving = ResolvedPrefix.resolving?(d.kind)

      with :ok <- sequence(d.sequence, session.resolved_through + 1 + index),
           :ok <- code(d),
           :ok <- event_binding(d, session),
           :ok <- resolving_order(resolving, retryable_tail) do
        {:cont, {:ok, resolved + if(resolving, do: 1, else: 0), retryable_tail or not resolving}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved, _tail} -> {:ok, resolved}
      error -> error
    end
  end

  defp sequence(actual, expected) when actual == expected, do: :ok
  defp sequence(_, _), do: {:error, :sequence}
  defp resolving_order(true, true), do: {:error, :retryable_tail}
  defp resolving_order(_, _), do: :ok

  defp code(%{kind: kind, rejection_code: code}) when kind in @rejections do
    if byte_size(code) in 1..64 and
         Enum.all?(:binary.bin_to_list(code), &(&1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_)),
       do: :ok,
       else: {:error, :rejection_code}
  end

  defp code(%{rejection_code: ""}), do: :ok
  defp code(_), do: {:error, :rejection_code}

  defp event_binding(%{event_id: "", kind: kind}, _session) when kind in @rejections, do: :ok

  defp event_binding(%{event_id: id, sequence: sequence}, session) when byte_size(id) == 16 do
    if Map.get(session.sent_events, sequence) == id, do: :ok, else: {:error, :event_binding}
  end

  defp event_binding(_, _), do: {:error, :event_binding}
end
