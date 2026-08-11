defmodule ServiceRadar.Notifications.StreamPublisher do
  @moduledoc """
  The durable half of the notification firehose (task 4.1.1).

  `Transports.Stream` fans an envelope out to connected subscribers over
  `Phoenix.PubSub`. That is the live path and it has no memory: a subscriber that
  is disconnected when an envelope is published never learns it existed. This
  module is the other half - it publishes the same envelope to a JetStream
  subject backed by a stream, so a reconnecting consumer resumes from its cursor
  and replays what it missed rather than silently losing it.

  ## Why the publish waits for an ack

  A plain `Gnat.pub/4` to a stream-captured subject is fire-and-forget: it
  returns `:ok` whether or not JetStream accepted the message, and it returns
  `:ok` when no stream captures the subject at all. That makes "durable" a claim
  nobody checked. `publish/3` issues a NATS *request* instead, so JetStream's
  PubAck (`%{"stream" => ..., "seq" => ...}`) is what proves persistence. A
  publish this module reports as `:ok` is one a reconnecting consumer can replay.

  This matters most in the failure that actually happens: the subject namespace
  is not in the broker allowlist, or the stream was never created. Both look
  identical to a fire-and-forget publisher - perfectly healthy - and both mean
  every notification on the firehose is being dropped.

  ## Self-healing stream creation

  `publish/3` treats "nothing responded on the subject" as "the stream may not
  exist yet", calls `ensure_stream/1`, and retries once. In practice that arrives
  as `{:error, :timeout}` rather than `{:error, :no_responders}`, because Gnat
  only reports the latter when the connection opted into `no_responders: true`
  and ServiceRadar's does not - which is also why `request/3` bounds the wait
  instead of inheriting Gnat's 60 second default.

  Stream creation is idempotent and safe to race across nodes. It is deliberately
  not a boot-time-only step: core can start before the broker is reachable, and a
  firehose that stays dead until the next restart because provisioning ran too
  early is worse than one that provisions on demand.

  A connection failure deliberately does not trigger that retry - see
  `retry_after_ensure?/2`.

  ## Subjects

  Topics are the transport's namespace (`notifications:stream`,
  `notifications:stream:<suffix>`); subjects are NATS's
  (`notifications.stream`, `notifications.stream.<suffix>`). `subject/1`
  translates, so the two namespaces stay in sync without either module knowing
  the other's separator.

  New subject namespaces are DENIED at the broker by default, so
  `#{inspect("notifications.>")}` must appear in the per-CN publish and subscribe
  allowlists in `helm/serviceradar/templates/nats.yaml` (tasks 4.1.2 - 4.1.3).

  ## Seams

  Every NATS call goes through an injectable seam (`:request`, `:connection`), so
  the tests here are `async: true` with no broker and no connection process.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  @stream_name "NOTIFICATIONS"
  @subject_root "notifications"
  @subject_wildcard "notifications.>"

  # Retention is time-and-size bounded rather than interest-based: an interest
  # stream discards a message once every known consumer has acked it, which is
  # exactly wrong here. The firehose exists so a consumer that was ABSENT can
  # come back and replay, and an absent consumer registers no interest.
  @default_max_age_ns 86_400_000_000_000
  @default_max_bytes 1_073_741_824

  # Bounds the JetStream request wait. See `request/3` for why inheriting Gnat's
  # 60_000 ms default would stall a dispatcher queue on a missing stream.
  @default_receive_timeout_ms 5_000

  @type seam_opts :: keyword()

  @doc "The JetStream stream backing the notification firehose."
  @spec stream_name() :: String.t()
  def stream_name, do: @stream_name

  @doc "The subject namespace the stream captures."
  @spec subject_wildcard() :: String.t()
  def subject_wildcard, do: @subject_wildcard

  @doc """
  Translates a transport topic into its NATS subject.

  `notifications:stream` becomes `notifications.stream`, and a suffixed topic
  keeps its suffix as a further token. A topic that is not in the notification
  namespace at all is published under `notifications.` + the sanitised topic
  rather than escaping the namespace, because a subject outside
  `#{inspect(@subject_wildcard)}` is denied at the broker and would be dropped.
  """
  @spec subject(String.t()) :: String.t()
  def subject(topic) when is_binary(topic) do
    tokens =
      topic
      |> String.split(":", trim: true)
      |> Enum.map(&sanitise_token/1)
      |> Enum.reject(&(&1 == ""))

    case tokens do
      [] -> @subject_root
      [@subject_root | rest] -> Enum.join([@subject_root | rest], ".")
      other -> Enum.join([@subject_root | other], ".")
    end
  end

  @doc """
  Publishes an envelope to the firehose stream, waiting for JetStream's ack.

  Returns `:ok` only when JetStream confirms persistence. Every other outcome is
  an `{:error, reason}` the caller should treat as retryable - the envelope is
  not durably recorded, so a subscriber replaying its cursor will not see it.

  ## Options

    * `:request` - `fun(subject, payload)` replacing the NATS request. Tests
      inject it.
    * `:connection` - `fun()` returning `{:ok, conn} | {:error, reason}`.
    * `:ensure_stream` - set `false` to skip the self-healing retry.
  """
  @spec publish(String.t(), map() | binary(), seam_opts()) :: :ok | {:error, term()}
  def publish(topic, envelope, opts \\ [])

  def publish(topic, envelope, opts) when is_binary(topic) and is_map(envelope) do
    case Jason.encode(envelope) do
      {:ok, payload} -> publish(topic, payload, opts)
      {:error, reason} -> {:error, {:envelope_not_encodable, reason}}
    end
  end

  def publish(topic, payload, opts) when is_binary(topic) and is_binary(payload) do
    subject = subject(topic)

    case do_publish(subject, payload, opts) do
      {:error, reason} ->
        if retry_after_ensure?(reason, opts) do
          retry_publish(subject, payload, opts)
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  @doc """
  Creates the firehose stream if it is missing.

  Idempotent and safe to race. A concurrent create with the *same* configuration
  is answered by JetStream with an ordinary success response, not an error, so
  two nodes racing both come away with `:ok` and no special case is needed.
  (Verified against NATS 2.14: a repeated identical `STREAM.CREATE` returns
  `did_create: true` rather than a collision.)

  A collision is therefore reported only when the stream exists with a
  **different** configuration (`err_code` 10058), and that is deliberately NOT
  treated as success. It means something owns the name with other subjects, so
  `notifications.>` is captured by nothing and every envelope published to the
  firehose is dropped. Swallowing it would leave the exact
  looks-healthy-but-silently-broken state this module exists to prevent; the
  caller gets `{:error, {:stream_config_conflict, description}}` and an operator
  gets a message naming the real problem.

  A server that answers an identical create with a bare "stream name already in
  use" - no mention of a differing configuration - is still treated as success,
  so this stays correct on older brokers.
  """
  @spec ensure_stream(seam_opts()) :: :ok | {:error, term()}
  def ensure_stream(opts \\ []) do
    payload =
      Jason.encode!(%{
        name: @stream_name,
        subjects: [@subject_wildcard],
        retention: "limits",
        storage: "file",
        discard: "old",
        num_replicas: Keyword.get(opts, :replicas, 1),
        max_age: Keyword.get(opts, :max_age, @default_max_age_ns),
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
      })

    case request(opts, js_api(opts) <> ".STREAM.CREATE." <> @stream_name, payload) do
      {:ok, _ack} ->
        :ok

      {:error, %{"description" => description}} when is_binary(description) ->
        classify_create_error(description)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The durable consumer options a firehose subscriber passes to
  `ServiceRadar.NATS.JetstreamConsumer.ensure_durable/2`.

  Exposed here so the subscriber does not restate the stream name, the subject,
  or the retention shape - the two halves of the firehose disagreeing about any
  of those is precisely the bug that makes replay silently return nothing.
  """
  @spec durable_consumer_opts(String.t(), keyword()) :: keyword()
  def durable_consumer_opts(consumer_name, opts \\ []) when is_binary(consumer_name) do
    [
      stream_name: @stream_name,
      consumer_name: consumer_name,
      filter_subject: Keyword.get(opts, :filter_subject, @subject_wildcard),
      deliver_policy: Keyword.get(opts, :deliver_policy, "new")
    ]
  end

  # --- publishing -----------------------------------------------------------

  defp do_publish(subject, payload, opts) do
    case request(opts, subject, payload) do
      {:ok, %{"stream" => stream, "seq" => seq}} ->
        Logger.debug(
          "notification firehose published subject=#{subject} stream=#{stream} seq=#{seq}"
        )

        :ok

      {:ok, other} ->
        {:error, {:unexpected_publish_ack, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_publish(subject, payload, opts) do
    opts = Keyword.put(opts, :ensure_stream, false)

    case ensure_stream(opts) do
      :ok -> do_publish(subject, payload, opts)
      {:error, reason} -> {:error, {:stream_unavailable, reason}}
    end
  end

  # "No responders" is JetStream saying nothing is listening on the subject,
  # which for a stream-captured subject means the stream is missing. A timeout is
  # the same condition on a Gnat build that surfaces it that way.
  #
  # Only those two reasons are worth a create-and-retry. Retrying a connection
  # error would call `ensure_stream/1` over the same dead connection and report
  # `:stream_unavailable`, burying the actual cause - the broker being
  # unreachable - under a wrong one.
  defp retry_after_ensure?(reason, opts) when is_list(opts) do
    Keyword.get(opts, :ensure_stream, true) != false and missing_stream?(reason)
  end

  defp missing_stream?(:timeout), do: true
  defp missing_stream?(:no_responders), do: true
  defp missing_stream?({:no_responders, _details}), do: true
  defp missing_stream?(_reason), do: false

  # Deliberately NOT `Gnat.Jetstream.API.Util.request/3`: it passes no options,
  # so it inherits Gnat's 60_000 ms default receive timeout. Gnat's
  # `no_responders` behaviour is off unless the connection opted in, and
  # ServiceRadar's does not, so "no stream captures this subject" does not fail
  # fast - it blocks for a full minute and then reports `:timeout`. A dispatcher
  # publishing from an Oban worker would stall the queue for a minute per
  # delivery, and the retry would stall it again. Bounding the wait here is what
  # turns a missing stream into a prompt retryable failure.
  defp request(opts, subject, payload) do
    case Keyword.get(opts, :request) do
      fun when is_function(fun, 2) ->
        fun.(subject, payload)

      nil ->
        with {:ok, conn} <- connection(opts) do
          conn
          |> Gnat.request(subject, payload, receive_timeout: receive_timeout(opts))
          |> decode_response()
        end
    end
  end

  defp receive_timeout(opts), do: Keyword.get(opts, :receive_timeout, @default_receive_timeout_ms)

  # Mirrors Util.request/3's decoding: JetStream answers on the same subject with
  # either a PubAck or an `error` object, and both arrive as a JSON body.
  defp decode_response({:ok, %{body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:undecodable_response, reason}}
    end
  end

  defp decode_response({:error, reason}), do: {:error, reason}

  defp connection(opts) do
    case Keyword.get(opts, :connection) do
      fun when is_function(fun, 0) -> fun.()
      nil -> Connection.get()
    end
  end

  defp js_api(opts) do
    opts
    |> Keyword.get(:domain)
    |> JetstreamConsumer.js_api()
  end

  defp classify_create_error(description) do
    normalised = String.downcase(description)

    cond do
      # err_code 10058. The name is taken by a stream capturing other subjects,
      # so nothing captures `notifications.>` and the firehose is dead. Naming it
      # is the whole point - a bare timeout on the next publish would not tell an
      # operator what to fix.
      String.contains?(normalised, "different configuration") ->
        {:error, {:stream_config_conflict, description}}

      # An older broker answering an identical create this way is a benign race.
      String.contains?(normalised, "already in use") ->
        :ok

      true ->
        {:error, description}
    end
  end

  # NATS subject tokens may not contain the separators the broker reserves.
  defp sanitise_token(token) do
    token
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> String.trim("_")
  end
end
