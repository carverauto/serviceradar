defmodule ServiceRadar.NATS.JetStreamPublish do
  @moduledoc """
  Publishes to a JetStream-captured subject and waits for the stream's PubAck.

  `ServiceRadar.NATS.Connection.publish/3` is a plain NATS publish: it returns
  `:ok` whether or not a stream stored the message. A producer that replaces a
  direct database write with a JetStream hop needs to know the message was
  stored, so this sends the publish as a request and treats anything other than
  a PubAck (`{"stream": ..., "seq": ...}`) as a failure.

  The wait is bounded: a subject no stream captures otherwise blocks for Gnat's
  default receive timeout.
  """

  alias ServiceRadar.NATS.Connection

  @default_timeout_ms 5_000

  @doc """
  Publishes `body` to `subject` and returns `:ok` once a stream has stored it.

  Options:

    * `:msg_id` - sets `Nats-Msg-Id`, so a stream with a duplicate window
      stores a retried publish once
    * `:timeout` - PubAck wait in milliseconds (default #{@default_timeout_ms})
    * `:request` - `(subject, body, request_opts -> {:ok, %{body: binary}} | {:error, term})`,
      replacing the NATS request (tests)
  """
  @spec publish(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(subject, body, opts \\ []) when is_binary(subject) and is_binary(body) do
    request_opts = request_opts(opts)

    with {:ok, %{body: ack}} <- request(subject, body, request_opts, opts),
         {:ok, %{"stream" => stream, "seq" => seq}} when is_binary(stream) and is_integer(seq) <-
           Jason.decode(ack) do
      :ok
    else
      {:ok, %{"error" => error}} -> {:error, {:jetstream, error}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_jetstream_ack, other}}
    end
  end

  defp request_opts(opts) do
    base = [receive_timeout: Keyword.get(opts, :timeout, @default_timeout_ms)]

    case Keyword.get(opts, :msg_id) do
      id when is_binary(id) and id != "" -> Keyword.put(base, :headers, [{"Nats-Msg-Id", id}])
      _ -> base
    end
  end

  defp request(subject, body, request_opts, opts) do
    case Keyword.get(opts, :request) do
      fun when is_function(fun, 3) ->
        fun.(subject, body, request_opts)

      nil ->
        with {:ok, conn} <- Connection.get() do
          Gnat.request(conn, subject, body, request_opts)
        end
    end
  end
end
