defmodule ServiceRadar.NATS.JetStreamPublish do
  @moduledoc """
  Publishes to a JetStream-captured subject and waits for the stream's PubAck.

  `ServiceRadar.NATS.Connection.publish/3` is a plain NATS publish: it returns
  `:ok` whether or not a stream stored the message. A producer that replaces a
  direct database write with a JetStream hop needs to know the message was
  stored, so this sends the publish as a request and treats anything other than
  a PubAck (`{"stream": ..., "seq": ...}` with a sequence above 0 and no
  `"error"`) as a failure.

  The wait is bounded: a subject no stream captures otherwise blocks for Gnat's
  default receive timeout.

  A broker that denies the publish never answers it (see
  `ServiceRadar.NATS.PublishDenials`). On the shared connection a denied publish
  therefore fails as `{:error, %ServiceRadar.NATS.PublishDeniedError{}}` rather than
  `{:error, :timeout}`, and while the denial is held further publishes of that
  subject fail the same way without being sent. A timeout the broker did not
  explain as a denial stays `{:error, :timeout}`: a slow broker is not a refusal.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.PublishDenials
  alias ServiceRadar.NATS.PublishDeniedError

  @default_timeout_ms 5_000

  @doc """
  Publishes `body` to `subject` and returns `:ok` once a stream has stored it.

  Options:

    * `:msg_id` - sets `Nats-Msg-Id`, so a stream with a duplicate window
      stores a retried publish once
    * `:headers` - further `{name, value}` headers, sent after `Nats-Msg-Id`
    * `:timeout` - PubAck wait in milliseconds (default #{@default_timeout_ms})
    * `:request` - `(subject, body, request_opts -> {:ok, %{body: binary}} | {:error, term})`,
      replacing the NATS request. A caller that owns its own connection passes it here;
      without it the publish uses `ServiceRadar.NATS.Connection`. Denials are classified
      only on that shared connection, the one this module can name.
  """
  @spec publish(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(subject, body, opts \\ []) when is_binary(subject) and is_binary(body) do
    with {:ok, _ack} <- publish_acked(subject, body, opts), do: :ok
  end

  @doc """
  Like `publish/3`, but returns the PubAck: the stream that stored the message, its
  sequence there, and whether the stream reported it as a duplicate of a message it
  already holds (`Nats-Msg-Id` within the duplicate window).
  """
  @spec publish_acked(String.t(), binary(), keyword()) ::
          {:ok, %{stream: String.t(), seq: pos_integer(), duplicate: boolean()}}
          | {:error, term()}
  def publish_acked(subject, body, opts \\ []) when is_binary(subject) and is_binary(body) do
    request_opts = request_opts(opts)

    with {:ok, %{body: ack}} <- request(subject, body, request_opts, opts) do
      ack |> Jason.decode() |> stored()
    end
  end

  # A stream that refuses a message (it is full, or the message breaks a limit)
  # still names itself in the reply, with sequence 0 beside the error. The error
  # is checked first so that reply is never read as a stored message.
  defp stored({:ok, %{"error" => error}}) when not is_nil(error),
    do: {:error, {:jetstream, error}}

  defp stored({:ok, %{"stream" => stream, "seq" => seq} = ack})
       when is_binary(stream) and is_integer(seq) and seq > 0 do
    {:ok, %{stream: stream, seq: seq, duplicate: Map.get(ack, "duplicate") == true}}
  end

  defp stored(other), do: {:error, {:invalid_jetstream_ack, other}}

  defp request_opts(opts) do
    base = [receive_timeout: Keyword.get(opts, :timeout, @default_timeout_ms)]

    msg_id =
      case Keyword.get(opts, :msg_id) do
        id when is_binary(id) and id != "" -> [{"Nats-Msg-Id", id}]
        _ -> []
      end

    case msg_id ++ Keyword.get(opts, :headers, []) do
      [] -> base
      headers -> Keyword.put(base, :headers, headers)
    end
  end

  defp request(subject, body, request_opts, opts) do
    case Keyword.get(opts, :request) do
      fun when is_function(fun, 3) ->
        fun.(subject, body, request_opts)

      nil ->
        with {:ok, conn} <- Connection.get() do
          request_on(conn, subject, body, request_opts)
        end
    end
  end

  defp request_on(conn, subject, body, request_opts) do
    if PublishDenials.held?(conn, subject) do
      {:error, %PublishDeniedError{subject: subject}}
    else
      started_ms = PublishDenials.now_ms()

      case Gnat.request(conn, subject, body, request_opts) do
        {:error, :timeout} = timeout ->
          if PublishDenials.denied_since?(conn, subject, started_ms),
            do: {:error, %PublishDeniedError{subject: subject}},
            else: timeout

        result ->
          result
      end
    end
  end
end
