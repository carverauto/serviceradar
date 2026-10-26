defmodule ServiceRadar.EventWriter.ConsumerReconciler do
  @moduledoc """
  The single owner of EventWriter's JetStream streams and durable consumers.

  Every core replica runs EventWriter workers that bind the same durables (see
  `ServiceRadar.EventWriter.Producer`). Anything that changes the server runs
  here instead, once per deployment, under the coordinator:

    * creating each configured stream and durable, and reconciling their
      shape and consumer config (`ServiceRadar.NATS.JetstreamConsumer.ensure_durable/2`);
    * deleting retired durables once every live durable is up;
    * the stream ownership reconcile timer (`ServiceRadar.EventWriter.StreamOwnership`);
    * the stream health event on a durable's transition to degraded and back.

  Replicas that each did this would race one another's `STREAM.UPDATE`s, keep
  one ownership grace-period clock each, record one health event per replica and,
  during a rolling deploy, fight over a durable's config.

  A durable's `max_ack_pending` is the per-worker value times the number of
  pipelines bound to it (`Config.consumers_per_durable/2`), so each worker keeps
  the in-flight budget one EventWriter had before and its warehouse batches still
  fill to half of it.

  Setup runs on every (re)connect. A stream that fails is retried on its own
  with backoff while the others stay up.
  """

  use GenServer

  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerSetup
  alias ServiceRadar.EventWriter.StreamOwnership
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  defstruct [
    :config,
    :conn,
    :monitor,
    :stream_health,
    :ownership,
    :owned_streams,
    connected: false,
    connect_failures: 0,
    failed: %{},
    degraded: %{}
  ]

  @doc """
  Starts the reconciler. `config` is the EventWriter config whose streams it
  owns (every stream of the shared and flow pipelines); it defaults to
  `default_config/0`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every stream any EventWriter pipeline consumes, under the shared pipeline's settings."
  @spec default_config() :: Config.t()
  def default_config do
    config = Config.load()
    flow = Config.load_flow()
    %{config | streams: config.streams ++ flow.streams}
  end

  @doc "Whether every configured durable is set up."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, _ -> %{running: false, connected: false, ready: false, failed_streams: []}
  end

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &default_config/0)

    state = %__MODULE__{
      config: config,
      stream_health:
        Application.get_env(
          :serviceradar_core,
          :event_writer_stream_health,
          ServiceRadar.EventWriter.StreamHealth
        ),
      # First-seen-unclaimed times live here, so a restart starts the grace
      # period again: that delays a claim and never makes one early.
      ownership: StreamOwnership.new(grace_period_ms: config.ownership_grace_period_ms),
      owned_streams: StreamOwnership.watched_streams(config.streams)
    }

    send(self(), :connect)
    schedule_ownership_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    failed = Map.keys(state.failed)

    {:reply,
     %{
       running: true,
       connected: state.connected,
       ready: state.connected and failed == [],
       failed_streams: failed
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case ConsumerSetup.open(state.config.nats) do
      {:ok, conn, monitor} ->
        Logger.info("EventWriter consumer reconciler connected to NATS JetStream")

        state = %{
          state
          | conn: conn,
            monitor: monitor,
            connected: true,
            connect_failures: 0,
            failed: %{}
        }

        {:noreply, ensure_all(state)}

      {:error, reason} ->
        failures = state.connect_failures + 1
        delay = ConsumerSetup.retry_delay(failures)

        Logger.warning(
          "EventWriter consumer reconciler NATS connection failed: #{inspect(reason)}, " <>
            "retrying in #{delay}ms"
        )

        Process.send_after(self(), :connect, delay)
        {:noreply, %{state | connect_failures: failures}}
    end
  end

  # The message names the connection it was scheduled for, so a retry left over
  # from before a reconnect is dropped: the reconnect set up every stream again.
  def handle_info({:retry_stream, conn, name}, %{conn: conn, connected: true} = state) do
    case Map.fetch(state.failed, name) do
      {:ok, entry} -> {:noreply, retry_stream(state, name, entry)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:retry_stream, _stale_conn, _name}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    failures = state.connect_failures + 1
    delay = ConsumerSetup.retry_delay(failures)

    Logger.warning(
      "EventWriter consumer reconciler NATS connection exited: #{inspect(reason)}, " <>
        "reconnecting in #{delay}ms"
    )

    Process.send_after(self(), :connect, delay)

    {:noreply,
     %{
       state
       | conn: nil,
         monitor: nil,
         connected: false,
         connect_failures: failures,
         failed: %{}
     }}
  end

  # The ownership reconcile timer (design D6 of update-jetstream-storage-budget):
  # a periodic tick, separate from the per-stream retries, that re-reads every
  # multi-owner stream EventWriter consumes and applies the claim rule. It only
  # issues STREAM.INFO / STREAM.UPDATE and never touches a consumer. Skipped
  # while disconnected: the tracker keeps its first-seen times, so the grace
  # period is measured across the outage.
  def handle_info(:ownership_reconcile, state) do
    state = reconcile_stream_ownership(state)
    schedule_ownership_reconcile(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: ConsumerSetup.close(state.conn)

  @doc false
  def reconcile_stream_ownership(%{owned_streams: owned} = state) when owned == %{}, do: state

  def reconcile_stream_ownership(%{connected: true, conn: conn} = state) when is_pid(conn) do
    request = fn topic, payload -> Util.request(conn, topic, payload) end
    %{state | ownership: StreamOwnership.reconcile(state.ownership, request, state.owned_streams)}
  end

  def reconcile_stream_ownership(state), do: state

  @doc """
  Creates or reconciles the stream and durable of one configured stream.
  """
  @spec ensure_stream(pid() | atom(), Config.t(), map()) :: :ok | {:error, term()}
  def ensure_stream(conn, %Config{} = config, stream) do
    with {:ok, ensured} <- JetstreamConsumer.ensure_durable(conn, ensure_opts(config, stream)) do
      ConsumerSetup.validate_resolved_stream(stream, ensured.stream_name)
    end
  catch
    # An unlinked transport can disappear between an API call and its reply.
    :exit, reason -> {:error, {:connection_exit, reason}}
  end

  @doc false
  # The durable config a stream gets. `max_ack_pending` is per worker: the
  # durable's server-side ceiling is that times the pipelines bound to it.
  def ensure_opts(%Config{} = config, stream) do
    flow? = Config.flows_stream_consumer?(stream)
    ack_wait_ns = config.ack_wait_ns || Config.default_ack_wait_ns()
    max_deliver = config.max_deliver || Config.default_max_deliver()

    per_worker_max_ack_pending =
      Map.get(stream, :consumer_max_ack_pending) || config.max_ack_pending ||
        Config.default_max_ack_pending()

    [
      stream_name: Config.jetstream_stream_name(stream),
      consumer_name: ConsumerSetup.durable_name(config, stream),
      filter_subject: stream.subject,
      description: "EventWriter consumer for #{stream.name}",
      ack_policy: :explicit,
      ack_wait: Map.get(stream, :consumer_ack_wait_ns, ack_wait_ns),
      deliver_policy: Map.get(stream, :consumer_deliver_policy),
      deliver_policy_if_absent: Map.get(stream, :consumer_deliver_policy_if_absent),
      max_ack_pending: per_worker_max_ack_pending * Config.consumers_per_durable(config, stream),
      max_deliver: Map.get(stream, :consumer_max_deliver, max_deliver),
      inactive_threshold: Map.get(stream, :consumer_inactive_threshold),
      stream_retention: Map.get(stream, :stream_retention),
      stream_storage: Map.get(stream, :stream_storage),
      stream_discard: Map.get(stream, :stream_discard),
      stream_replicas: Map.get(stream, :stream_replicas),
      stream_max_bytes: Map.get(stream, :stream_max_bytes),
      stream_max_age: Map.get(stream, :stream_max_age),
      stream_duplicate_window: Map.get(stream, :stream_duplicate_window),
      # Flow path: never fall back onto `events` (strands durables after rehome).
      allow_stream_fallback: ConsumerSetup.allow_stream_fallback?(stream),
      # A stream a collector may own carries the `event-writer` claim: it is
      # created with that claim, and its shape is reconciled only while the
      # claim is EventWriter's (design D6). Without a claim, a flow stream only
      # merges subjects, as before.
      stream_owner_claim: Map.get(stream, :stream_owner_claim),
      reconcile_stream_shape: Map.get(stream, :reconcile_stream_shape, not flow?),
      # Legacy events drain consumers must not create/reshape the shared stream.
      ensure_stream: Map.get(stream, :ensure_stream, true)
    ]
  end

  @doc false
  # Sets up every configured stream on the current connection.
  def ensure_all(%{config: config} = state) do
    state =
      Enum.reduce(config.streams, state, fn stream, acc ->
        case ensure_stream(acc.conn, config, stream) do
          :ok ->
            record_recovered(acc, stream.name)

          {:error, reason} ->
            log_failure(config, stream, reason)
            track_failure(acc, stream, reason)
        end
      end)

    maybe_retire(state)
  end

  # A best-effort stream is a backlog drain, not part of the live pipeline: a
  # failure is logged and set up again on the next connect, never retried on a
  # timer and never holding back retirement.
  defp track_failure(state, stream, reason) do
    if Map.get(stream, :best_effort, false) do
      state
    else
      {state, attempt} = record_failed(state, stream.name, reason)
      schedule_retry(state.conn, stream.name, attempt)
      entry = %{stream: stream, attempt: attempt}
      %{state | failed: Map.put(state.failed, stream.name, entry)}
    end
  end

  defp retry_stream(state, name, %{stream: stream} = entry) do
    case ensure_stream(state.conn, state.config, stream) do
      :ok ->
        Logger.info("EventWriter durable set up after retry",
          consumer: name,
          failed_attempts: entry.attempt
        )

        state
        |> record_recovered(name)
        |> Map.update!(:failed, &Map.delete(&1, name))
        |> maybe_retire()

      {:error, reason} ->
        {state, next} = record_failed(state, name, reason)

        Logger.warning("EventWriter durable setup still failing; retrying this stream only",
          consumer: name,
          attempt: next,
          retry_in_ms: ConsumerSetup.retry_delay(next),
          reason: inspect(reason)
        )

        schedule_retry(state.conn, name, next)
        %{state | failed: Map.put(state.failed, name, %{entry | attempt: next})}
    end
  end

  # A retired durable is deleted only once every live durable is up, since the
  # one still failing may be its replacement.
  defp maybe_retire(%{failed: failed} = state) when failed == %{} do
    retire_consumers(state.conn, state.config.retired_consumers)
    state
  end

  defp maybe_retire(state), do: state

  # Best effort: a retired durable holds no work anyone needs, so failing to
  # delete it is logged and retried on the next connect, never fatal.
  defp retire_consumers(conn, retired) do
    Enum.each(retired, fn %{stream_name: stream_name, consumer_name: consumer_name} ->
      case JetstreamConsumer.delete_durable(conn, stream_name, consumer_name) do
        {:ok, :deleted} ->
          Logger.info(
            "EventWriter deleted retired JetStream consumer #{stream_name}/#{consumer_name}",
            stream: stream_name,
            durable: consumer_name
          )

        {:ok, :absent} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "EventWriter could not delete retired JetStream consumer " <>
              "#{stream_name}/#{consumer_name}: #{inspect(reason)}",
            stream: stream_name,
            durable: consumer_name,
            reason: inspect(reason)
          )
      end
    end)
  end

  # Health is transition-based and survives reconnects: `degraded` maps a stream
  # to its consecutive failed attempts and is only cleared when it sets up, so a
  # reconnect neither repeats a degraded event nor leaves a recovered stream
  # reported as degraded.
  defp record_failed(state, name, reason) do
    attempt = Map.get(state.degraded, name, 0) + 1
    state.stream_health.consumer_setup_failed(name, reason, attempt)
    {%{state | degraded: Map.put(state.degraded, name, attempt)}, attempt}
  end

  defp record_recovered(state, name) do
    case Map.pop(state.degraded, name) do
      {nil, _degraded} ->
        state

      {attempts, degraded} ->
        state.stream_health.consumer_setup_recovered(name, attempts)
        %{state | degraded: degraded}
    end
  end

  defp log_failure(config, stream, reason) do
    {diagnostic, metadata} = ConsumerSetup.describe_failure(config, stream, reason)

    if Map.get(stream, :best_effort, false) do
      Logger.warning("EventWriter skipping best-effort drain consumer " <> diagnostic, metadata)
    else
      Logger.error("Failed to initialize EventWriter durable consumer " <> diagnostic, metadata)
    end
  end

  defp schedule_retry(conn, name, attempt) do
    Process.send_after(self(), {:retry_stream, conn, name}, ConsumerSetup.retry_delay(attempt))
  end

  defp schedule_ownership_reconcile(%{owned_streams: owned}) when owned == %{}, do: :ok

  defp schedule_ownership_reconcile(%{config: config}) do
    interval =
      config.ownership_reconcile_interval_ms || Config.default_ownership_reconcile_interval_ms()

    Process.send_after(self(), :ownership_reconcile, interval)
  end
end
