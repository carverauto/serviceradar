defmodule ServiceRadar.NATS.DurablePublish do
  @moduledoc """
  Publishes internally produced telemetry to JetStream without losing it when
  NATS is unavailable.

  `publish/3` sends through `ServiceRadar.NATS.JetStreamPublish`, which waits
  for the stream's PubAck. When that fails, the message is stored as a
  `ServiceRadar.NATS.DurablePublishWorker` job in CNPG and retried until a
  stream acknowledges it. `msg_id` is the `Nats-Msg-Id`, so a stream
  deduplicates a publish the worker repeats, and every consumer of these
  subjects stores idempotently on the same id.

  `:on_published` names work that must run exactly once, after the message is
  durable in JetStream: for an internal OCSF event, its northbound handlers.
  It runs here after a direct PubAck, or in the worker after its own; never
  both, and never before the message is stored.

  ## Inside a database transaction: an outbox

  A producer that publishes from inside a transaction (an Ash action's
  after_action hook, a processor's `Repo.transaction`) must not announce a
  change that may still roll back. There the message is only stored as the
  retry job, in the same transaction: it commits or rolls back with the
  caller, and the worker publishes it after commit.
  """

  alias ServiceRadar.NATS.DurablePublishWorker
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @type on_published :: :northbound_handlers | nil

  @doc """
  Publishes `body` to `subject`.

  Returns `:ok` once a stream stored it, `{:ok, :enqueued}` when the publish
  failed and the durable retry job was stored, or `{:error, reason}` when
  neither the publish nor the retry job could be stored.

  Options:

    * `:msg_id` (required) - the message's stable identity
    * `:on_published` - `:northbound_handlers` to run an OCSF event's handlers
      once the message is durable
    * `:publish` - replaces `JetStreamPublish.publish/3` (tests)
    * `:in_transaction?` - replaces `ServiceRadar.Repo.in_transaction?/0` (tests)
    * `:enqueue` - replaces the retry-job insert (tests)
    * `:after_publish` - replaces the `:on_published` runner (tests)
  """
  @spec publish(String.t(), binary(), keyword()) :: :ok | {:ok, :enqueued} | {:error, term()}
  def publish(subject, body, opts) when is_binary(subject) and is_binary(body) do
    msg_id = Keyword.fetch!(opts, :msg_id)
    on_published = Keyword.get(opts, :on_published)

    if Keyword.get(opts, :in_transaction?, &Repo.in_transaction?/0).() do
      enqueue_retry(subject, body, msg_id, on_published, opts)
    else
      publish_now(subject, body, msg_id, on_published, opts)
    end
  end

  defp publish_now(subject, body, msg_id, on_published, opts) do
    publisher = publisher()
    publish = Keyword.get(opts, :publish, &publisher.publish/3)

    case publish.(subject, body, msg_id: msg_id) do
      :ok ->
        after_publish(opts).(on_published, body)
        :ok

      {:error, reason} ->
        Logger.warning("JetStream publish failed; retrying from a durable job",
          subject: subject,
          msg_id: msg_id,
          reason: inspect(reason)
        )

        enqueue_retry(subject, body, msg_id, on_published, opts)
    end
  end

  @doc """
  The module that performs the acknowledged publish: `JetStreamPublish`,
  unless `:internal_telemetry_publisher` names another module with the same
  `publish/3` contract. The test environment configures one that hands the
  message straight to the EventWriter processor for its subject.
  """
  @spec publisher() :: module()
  def publisher,
    do: Application.get_env(:serviceradar_core, :internal_telemetry_publisher, JetStreamPublish)

  @doc false
  # Runs the post-publish work for a message that is now durable in JetStream.
  @spec run_on_published(on_published() | String.t(), binary()) :: :ok
  def run_on_published(on_published, body)

  def run_on_published(nil, _body), do: :ok

  def run_on_published(on_published, body)
      when on_published in [:northbound_handlers, "northbound_handlers"] do
    case Jason.decode(body) do
      {:ok, event} ->
        ServiceRadar.Events.OcsfEventPublisher.run_northbound_handlers(event)

      {:error, reason} ->
        Logger.warning("Published event body is not JSON; handlers not run",
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp after_publish(opts), do: Keyword.get(opts, :after_publish, &run_on_published/2)

  defp enqueue_retry(subject, body, msg_id, on_published, opts) do
    job =
      DurablePublishWorker.new(%{
        "subject" => subject,
        "body" => body,
        "msg_id" => msg_id,
        "on_published" => on_published && Atom.to_string(on_published)
      })

    case Keyword.get(opts, :enqueue, &ObanSupport.safe_insert/1).(job) do
      {:ok, _job} ->
        {:ok, :enqueued}

      {:error, reason} ->
        Logger.error(
          "Internal telemetry lost: it could be neither published nor queued for publish",
          subject: subject,
          msg_id: msg_id,
          reason: inspect(reason)
        )

        {:error, {:publish_and_enqueue_failed, reason}}
    end
  end
end
