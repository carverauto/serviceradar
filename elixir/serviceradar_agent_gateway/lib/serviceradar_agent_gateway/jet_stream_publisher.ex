defmodule ServiceRadarAgentGateway.JetStreamPublisher do
  @moduledoc """
  Project-owned JetStream publish-with-PubAck for the durable edge result relay
  (unify-sweep-results-proto task 3.3).

  Unlike `ServiceRadar.NATS.Connection.publish/3` (fire-and-forget `Gnat.pub`),
  a durable relay MUST observe the server's `PubAck` before it may report a
  frame durable. This module sends a JetStream publish *request* (subject +
  `Nats-Msg-Id` for de-duplication + `Nats-Expected-Stream` to fence the target
  stream), waits for the reply, parses the `PubAck`, and classifies any error so
  the caller can withhold the resolved prefix (retryable) or route to the DLQ
  (permanent).

  Durability is the parsed `PubAck` returned here — never gRPC success, never a
  fire-and-forget publish. The classification mirrors the Go reference core
  `go/pkg/edge/gwpublish` (`:capacity`/`:timeout` retryable; `:protocol`/
  `:permanent` not).
  """

  alias ServiceRadar.NATS.Connection

  require Logger

  @type pub_ack :: %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}
  @type error_class :: :capacity | :timeout | :protocol | :permanent

  @default_timeout 5_000

  @doc """
  Publishes `payload` to `subject` with `headers` and returns the parsed PubAck.

  `headers` should already include `Nats-Msg-Id` and `Nats-Expected-Stream`.
  Options:

    * `:connection` — the connection module (default `ServiceRadar.NATS.Connection`);
      injectable for tests.
    * `:receive_timeout` — PubAck wait in ms (default #{@default_timeout}).
  """
  @spec publish(String.t(), binary(), list(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()}
  def publish(subject, payload, headers, opts \\ []) do
    conn = Keyword.get(opts, :connection, Connection)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case conn.request(subject, payload, headers: headers, receive_timeout: timeout) do
      {:ok, %{body: body}} ->
        parse_ack(body)

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, classify_transport(reason)}
    end
  end

  @doc """
  Parses a JetStream PubAck reply body. A success body is
  `{"stream","seq","duplicate"?}`; an error body carries an `"error"` object.
  """
  @spec parse_ack(binary()) :: {:ok, pub_ack()} | {:error, error_class()}
  def parse_ack(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        {:error, classify_ack_error(error)}

      {:ok, %{"stream" => stream, "seq" => seq} = ack}
      when is_binary(stream) and is_integer(seq) ->
        {:ok, %{stream: stream, seq: seq, duplicate: Map.get(ack, "duplicate", false) == true}}

      _ ->
        {:error, :protocol}
    end
  end

  def parse_ack(_), do: {:error, :protocol}

  @doc "Whether an error class should be retried (withhold progress) vs DLQ'd."
  @spec retryable?(error_class()) :: boolean()
  def retryable?(class), do: class in [:capacity, :timeout]

  # Classify a JetStream ack error object
  # (`%{"code","description","err_code"}`). Capacity/back-pressure is retryable;
  # an expected-stream/sequence fence failure is a protocol error; anything else
  # is a permanent rejection routed to the DLQ.
  defp classify_ack_error(%{} = err) do
    code = err["code"]
    desc = err["description"] |> to_string() |> String.downcase()

    cond do
      code == 503 -> :capacity
      String.contains?(desc, "no responders") -> :capacity
      String.contains?(desc, "insufficient resources") -> :capacity
      String.contains?(desc, "maximum") and String.contains?(desc, "exceeded") -> :capacity
      String.contains?(desc, "expected") -> :protocol
      String.contains?(desc, "wrong last sequence") -> :protocol
      true -> :permanent
    end
  end

  defp classify_ack_error(_), do: :permanent

  # An unknown transport failure is treated as a retryable timeout -- never
  # silently dropped and never treated as durable success.
  defp classify_transport(:no_responders), do: :capacity
  defp classify_transport({:nats_not_connected, _}), do: :capacity
  defp classify_transport({:nats_connection_died, _}), do: :capacity
  defp classify_transport(_), do: :timeout
end
