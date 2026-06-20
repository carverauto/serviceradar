defmodule ServiceRadar.EventWriter.JetStreamAck do
  @moduledoc """
  Parses JetStream ACK reply subjects.

  The server encodes delivery attempt and sequence metadata in reply subjects:
  `$JS.ACK.<stream>.<consumer>.<delivered>.<stream_seq>.<consumer_seq>.<timestamp>.<pending>`.
  Domain/account-prefixed variants keep the same numeric suffix, so parsing is
  anchored from the right.

  EventWriter dead-letter handling is a terminal-delivery telemetry/log signal;
  it does not persist poison payloads into a replayable DLQ.
  """

  @type t :: %{
          stream: String.t(),
          consumer: String.t(),
          delivery_count: pos_integer(),
          stream_sequence: non_neg_integer(),
          consumer_sequence: non_neg_integer(),
          timestamp: non_neg_integer(),
          pending: non_neg_integer()
        }

  @spec parse(term()) :: t() | nil
  def parse("$JS.ACK." <> rest) do
    tokens = String.split(rest, ".", trim: true)

    with {prefix, [delivered, stream_seq, consumer_seq, timestamp, pending]}
         when length(prefix) >= 2 <-
           Enum.split(tokens, max(length(tokens) - 5, 0)),
         {:ok, delivery_count} <- parse_positive(delivered),
         {:ok, stream_sequence} <- parse_non_negative(stream_seq),
         {:ok, consumer_sequence} <- parse_non_negative(consumer_seq),
         {:ok, timestamp} <- parse_non_negative(timestamp),
         {:ok, pending} <- parse_non_negative(pending) do
      [consumer, stream | _domain_or_account] = Enum.reverse(prefix)

      %{
        stream: stream,
        consumer: consumer,
        delivery_count: delivery_count,
        stream_sequence: stream_sequence,
        consumer_sequence: consumer_sequence,
        timestamp: timestamp,
        pending: pending
      }
    else
      _ -> nil
    end
  end

  def parse(_reply_to), do: nil

  defp parse_positive(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_integer(_value), do: :error
end
