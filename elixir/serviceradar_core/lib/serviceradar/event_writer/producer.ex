defmodule ServiceRadar.EventWriter.Producer do
  @moduledoc """
  Broadway producer for NATS JetStream.

  Connects to NATS JetStream and consumes messages from configured streams,
  delivering them to the Broadway pipeline for processing.

  ## Implementation Notes

  This producer creates one durable PULL consumer per configured stream. It asks
  JetStream for messages only when Broadway has downstream demand and local
  in-flight capacity. Flow control therefore has two enforcement points:

    1. **Server-side**: `max_ack_pending` caps delivered-but-unacked messages for
       each durable. In pull mode this is a safety ceiling, not a push prefetch
       target.
    2. **Producer-side**: `@max_buffered_messages` caps the in-process buffer of
       messages already fetched and waiting on Broadway demand. Anything beyond
       the cap is NAK'd back to the server instead of being retained in this
       process's heap.

  Broadway demand drains the buffer; messages are acked only after the pipeline
  finishes processing them, which is what releases the server's `max_ack_pending`
  budget and pulls the next batch.

  ## Message Format

  Each message delivered to Broadway has:
  - `data` - The message payload (binary)
  - `metadata` - Map containing `:subject`, `:reply_to`, `:headers`
  - `ack_data` - Data needed for acknowledgment

  ## Acknowledgment

  Messages are acknowledged after successful processing by the Broadway pipeline.
  Failed messages are NAK'd for redelivery according to the consumer's retry policy.
  """

  @behaviour Broadway.Producer

  use GenStage

  alias Gnat.Jetstream.API.Consumer, as: JetstreamConsumerApi
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.JetStreamAck
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.NATS.JetstreamConsumer

  require Logger

  # Used only when long-poll expires is disabled (legacy no_wait path).
  @fetch_interval 100
  # Slow idle tick while long-polling so reconnect hygiene still runs.
  @long_poll_idle_interval 5_000
  @reconnect_delay 5_000
  # Slack added to pull_expires so a late empty-status can still arrive.
  @long_poll_stale_slack_ms 5_000
  # no_wait pulls should return immediately; 5s covers a lost reply.
  @no_wait_stale_pull_timeout_ms 5_000

  # Hard cap on the number of fully-formed Broadway events buffered in this
  # process while waiting for downstream demand. Sized off the configured
  # per-consumer max_ack_pending so the in-process buffer never exceeds what the
  # server is allowed to push, with a small multiplier for the (few) consumers
  # that share this producer. Messages beyond the cap are NAK'd so the server
  # retains them rather than this process growing its heap.
  @buffer_multiplier 2
  @min_buffer 64

  defstruct [
    :config,
    :conn,
    :consumer_context,
    :demand,
    :connected,
    :streams,
    :pending_messages,
    :pending_count,
    :pull_inflight,
    :pull_inflight_by_subject,
    :pull_inflight_started_at,
    :sid_to_pull_subject,
    :max_buffered,
    :dropped_overflow,
    :pull_subjects
  ]

  # Client API

  def start_link(%Config{} = config) do
    GenStage.start_link(__MODULE__, config, name: config.producer_name || __MODULE__)
  end

  # GenStage callbacks

  @impl true
  def init(%Config{} = config) do
    max_buffered = max_buffered(config)

    Logger.info("Starting EventWriter producer",
      nats_host: config.nats.host,
      max_ack_pending: config.max_ack_pending,
      max_buffered: max_buffered
    )

    state = %__MODULE__{
      config: config,
      demand: 0,
      connected: false,
      streams: config.streams,
      pending_messages: :queue.new(),
      pending_count: 0,
      pull_inflight: 0,
      pull_inflight_by_subject: %{},
      pull_inflight_started_at: %{},
      sid_to_pull_subject: %{},
      max_buffered: max_buffered,
      dropped_overflow: 0,
      pull_subjects: MapSet.new()
    }

    # Start connection asynchronously
    send(self(), :connect)

    {:producer, state}
  end

  @doc false
  # Producer-side buffer ceiling. Derived from the per-consumer server-side
  # max_ack_pending so the in-process buffer can never exceed what the server is
  # allowed to push.
  @spec max_buffered(Config.t()) :: pos_integer()
  def max_buffered(%Config{max_ack_pending: max_ack_pending})
      when is_integer(max_ack_pending) and max_ack_pending > 0 do
    max(@min_buffer, max_ack_pending * @buffer_multiplier)
  end

  def max_buffered(%Config{}), do: max(@min_buffer, Config.default_max_ack_pending())

  @doc """
  How long a pull may stay in `pull_inflight_by_subject` before it is treated as lost.

  Long-poll pipelines get `pull_expires` plus slack so a late empty-status can
  still land. Shared no_wait pulls use a short fixed deadline: they should
  return immediately, so anything still counted after that is a dropped reply
  (consumer leader change, lost inbox frame).
  """
  @spec stale_pull_timeout_ms(Config.t()) :: pos_integer()
  def stale_pull_timeout_ms(%Config{pull_expires_ns: expires})
      when is_integer(expires) and expires > 0 do
    div(expires, 1_000_000) + @long_poll_stale_slack_ms
  end

  def stale_pull_timeout_ms(_config), do: @no_wait_stale_pull_timeout_ms

  @impl true
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    new_demand = demand + incoming_demand
    state = %{state | demand: new_demand}

    if state.connected and new_demand > 0 do
      {messages, state} =
        state
        |> expire_stale_pulls(System.monotonic_time(:millisecond))
        |> drain_pending_messages()
        |> maybe_request_pull_messages()

      {:noreply, messages, state}
    else
      {:noreply, [], state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.config) do
      {:ok, conn, consumer_context} ->
        Logger.info("EventWriter connected to NATS JetStream")

        :telemetry.execute(
          [:serviceradar, :event_writer, :connected],
          %{count: 1},
          %{host: state.config.nats.host}
        )

        sid_map = Map.get(consumer_context, :sid_to_pull_subject, %{})

        new_state = %{
          state
          | conn: conn,
            consumer_context: consumer_context,
            connected: true,
            sid_to_pull_subject: sid_map,
            pull_subjects: Map.get(consumer_context, :pull_subjects, MapSet.new())
        }

        # Schedule periodic / idle fetch tick (long-poll producers use a slower tick).
        schedule_fetch(new_state)

        {:noreply, [], new_state}

      {:error, reason} ->
        Logger.warning("EventWriter NATS connection failed: #{inspect(reason)}, retrying...")

        :telemetry.execute(
          [:serviceradar, :event_writer, :connection_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        Process.send_after(self(), :connect, @reconnect_delay)
        {:noreply, [], state}
    end
  end

  def handle_info(:fetch, state) do
    handle_info({:fetch, System.monotonic_time(:millisecond)}, state)
  end

  def handle_info({:fetch, now_ms}, state) when is_integer(now_ms) do
    state = expire_stale_pulls(state, now_ms)

    if state.connected and state.demand > 0 do
      {messages, state} =
        state
        |> drain_pending_messages()
        |> maybe_request_pull_messages()

      schedule_fetch(state)
      {:noreply, messages, state}
    else
      schedule_fetch(state)
      {:noreply, [], state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: conn} = state) when pid == conn do
    Logger.warning("NATS connection process died: #{inspect(reason)}")
    send(self(), :connect)

    {:noreply, [],
     %{
       state
       | connected: false,
         conn: nil,
         consumer_context: nil,
         pull_inflight: 0,
         pull_inflight_by_subject: %{},
         pull_inflight_started_at: %{}
     }}
  end

  # Handle incoming NATS messages from JetStream pull reply subjects.
  def handle_info({:msg, %{body: body, topic: subject, reply_to: reply_to} = msg}, state) do
    # Data messages carry the original JetStream subject on :topic; status/empty
    # pulls carry the pull inbox topic. Inflight accounting is always keyed by
    # the pull inbox subject, resolved via Gnat :sid when present.
    pull_key = pull_key_for_msg(msg, state)

    cond do
      pull_status_message?(msg, state) ->
        # Expiry/empty status: free the outstanding pull slot. Immediate repull
        # only for long-poll mode — no_wait shared consumers must keep 100ms pacing.
        state = clear_pull_inflight(state, pull_key)
        EventWriterTelemetry.emit_queue(state, :pull_status, pull_key)

        if state.connected and state.demand > 0 and long_poll_mode?(state) do
          {messages, state} =
            state
            |> drain_pending_messages()
            |> maybe_request_pull_messages()

          {:noreply, messages, state}
        else
          {:noreply, [], state}
        end

      state.pending_count >= state.max_buffered ->
        # Producer-side overflow guard: the in-process buffer is full. NAK the
        # message so the server retains it (and respects max_ack_pending) rather
        # than letting this process's heap grow unbounded -- the OOM regression.
        nak_overflow(state.conn, reply_to)

        state =
          state
          |> decrement_pull_inflight(pull_key)
          |> maybe_warn_overflow()

        EventWriterTelemetry.emit_queue(state, :overflow, subject)
        {:noreply, [], state}

      true ->
        state
        |> decrement_pull_inflight(pull_key)
        |> buffer_message(body, subject, reply_to, msg)
    end
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  # Buffers a freshly received JetStream message. `pending_messages` is an
  # Erlang queue so enqueue and drain are O(1) per message without list reversal.
  defp buffer_message(state, body, subject, reply_to, msg) do
    headers = Map.get(msg, :headers, %{})
    original_subject = extract_original_subject(subject, headers)
    jetstream_ack = JetStreamAck.parse(reply_to)
    max_deliver = max_deliver_for(state.config, jetstream_ack, original_subject)

    broadway_event = %{
      data: body,
      metadata: %{
        subject: original_subject,
        reply_to: reply_to,
        headers: headers,
        jetstream_ack: jetstream_ack,
        max_deliver: max_deliver,
        received_at: DateTime.utc_now(),
        received_monotonic: System.monotonic_time()
      },
      ack_data: %{
        conn: state.conn,
        reply_to: reply_to,
        ack_fun: build_ack_fun(state.conn, reply_to)
      }
    }

    state = %{
      state
      | pending_messages: :queue.in(broadway_event, state.pending_messages),
        pending_count: state.pending_count + 1
    }

    EventWriterTelemetry.emit_queue(state, :enqueue, original_subject)

    if state.demand > 0 do
      {messages, state} =
        state
        |> drain_pending_messages()
        |> maybe_request_pull_messages()

      {:noreply, messages, state}
    else
      {:noreply, [], state}
    end
  end

  # NAK an overflow message so the JetStream server holds it (within
  # max_ack_pending) instead of this process buffering it. Falls back silently
  # when there is no reply_to (core NATS).
  defp nak_overflow(conn, reply_to) when is_binary(reply_to) and reply_to != "" do
    safe_ack_publish(conn, reply_to, "-NAK")
  end

  defp nak_overflow(_conn, _reply_to), do: :ok

  # Emits an overflow telemetry signal, rate-limited to one log line per 1000
  # drops so a sustained backlog cannot itself flood the logs.
  defp maybe_warn_overflow(state) do
    dropped = state.dropped_overflow + 1

    :telemetry.execute(
      [:serviceradar, :event_writer, :producer, :overflow],
      %{count: 1},
      %{max_buffered: state.max_buffered}
    )

    if rem(dropped, 1_000) == 1 do
      Logger.warning("EventWriter producer buffer full; NAKing overflow to the server",
        max_buffered: state.max_buffered,
        dropped_total: dropped
      )
    end

    %{state | dropped_overflow: dropped}
  end

  defp connect(%Config{} = config) do
    connection_settings = build_connection_settings(config.nats)

    case connection_settings do
      {:error, reason} ->
        {:error, reason}

      settings ->
        case Gnat.start_link(settings) do
          {:ok, conn} ->
            case setup_jetstream_consumers(conn, config) do
              {:ok, consumer_context} ->
                Process.monitor(conn)
                Process.unlink(conn)
                {:ok, conn, consumer_context}

              {:error, reason} ->
                # setup_jetstream_consumers already stops conn safely (unlinked).
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp build_connection_settings(nats_config) do
    settings = %{
      host: nats_config.host,
      port: nats_config.port
    }

    settings =
      case apply_auth_settings(settings, nats_config) do
        {:ok, updated} -> updated
        {:error, reason} -> {:error, reason}
      end

    case settings do
      {:error, reason} ->
        {:error, reason}

      updated ->
        add_tls_settings(updated, nats_config.tls)
    end
  end

  defp add_tls_settings(settings, tls) do
    case tls do
      true ->
        Map.put(settings, :tls, true)

      tls_opts when is_list(tls_opts) ->
        settings
        |> Map.put(:tls, true)
        |> Map.put(:ssl_opts, tls_opts)

      _ ->
        settings
    end
  end

  defp apply_auth_settings(settings, nats_config) do
    jwt = normalize(nats_config.jwt)
    nkey_seed = normalize(nats_config.nkey_seed)
    user = normalize(nats_config.user)

    cond do
      nkey_seed != nil ->
        settings =
          settings
          |> Map.put(:nkey_seed, nkey_seed)
          |> Map.put(:auth_required, true)

        settings =
          if jwt == nil do
            settings
          else
            Map.put(settings, :jwt, jwt)
          end

        {:ok, settings}

      jwt != nil ->
        {:error, :missing_nkey_seed}

      user != nil ->
        {:ok, Map.merge(settings, %{user: user, password: nats_config.password})}

      true ->
        {:ok, settings}
    end
  end

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value

  @doc false
  def setup_jetstream_consumers(conn, config) do
    # Resolve flow-control values with defaults so a Config built directly (e.g.
    # in tests) without going through Config.load/0 still gets a bounded consumer.
    max_ack_pending = config.max_ack_pending || Config.default_max_ack_pending()
    ack_wait_ns = config.ack_wait_ns || Config.default_ack_wait_ns()
    max_deliver = config.max_deliver || Config.default_max_deliver()

    default_pull_batch_size =
      config.consumer_pull_batch_size || Config.default_consumer_pull_batch_size()

    results =
      Enum.map(config.streams, fn stream ->
        {stream,
         setup_one_consumer(
           conn,
           config,
           stream,
           ack_wait_ns,
           max_ack_pending,
           max_deliver,
           default_pull_batch_size
         )}
      end)

    finalize_consumer_setup(conn, config, results)
  end

  defp finalize_consumer_setup(conn, %Config{} = config, results) when is_list(results) do
    expected_count = length(config.streams)

    consumers = for {_stream, {:ok, consumer}} <- results, do: consumer

    # A `best_effort` stream is a backlog drain, not part of the live pipeline.
    # Failing one must not unsubscribe the healthy consumers and re-arm the
    # whole connection every @reconnect_delay ms: on a deployment whose `events`
    # stream never carried a given flow subject, that turned a cosmetic mismatch
    # into a permanent flow-ingestion outage.
    {optional_failures, failures} =
      results
      |> Enum.filter(&match?({_stream, {:error, _}}, &1))
      |> Enum.split_with(fn {stream, _} -> Map.get(stream, :best_effort, false) end)

    Enum.each(optional_failures, fn {stream, {:error, reason}} ->
      log_consumer_setup_failure(:best_effort, config, stream, reason)
    end)

    Enum.each(failures, fn {stream, {:error, reason}} ->
      log_consumer_setup_failure(:required, config, stream, reason)
    end)

    cond do
      expected_count == 0 ->
        safe_stop_conn(conn)
        {:error, :no_streams_configured}

      failures != [] ->
        # Do not accept a partial flow (or shared) pipeline; close connection so
        # leaked inbox subscriptions cannot duplicate replies after reconnect.
        Enum.each(consumers, fn c -> safe_unsub(conn, c.sid) end)
        safe_stop_conn(conn)

        {:error,
         {:consumer_setup_failed,
          Enum.map(failures, fn {_stream, {:error, reason}} -> reason end)}}

      true ->
        pull_subjects = MapSet.new(consumers, & &1.pull_subject)
        sid_to_pull = Map.new(consumers, fn c -> {c.sid, c.pull_subject} end)

        {:ok,
         %{
           conn: conn,
           consumer_name: config.consumer_name,
           consumers: consumers,
           pull_subjects: pull_subjects,
           sid_to_pull_subject: sid_to_pull
         }}
    end
  end

  defp log_consumer_setup_failure(classification, config, stream, reason) do
    name = Map.fetch!(stream, :name)
    stream_name = Config.jetstream_stream_name(stream)
    durable_key = Map.get(stream, :durable_source_name) || name
    durable_name = Config.durable_name(config.consumer_name, durable_key)
    filter_subject = Map.fetch!(stream, :subject)

    diagnostic =
      "name=#{inspect(name)} durable=#{inspect(durable_name)} " <>
        "stream=#{inspect(stream_name)} filter_subject=#{inspect(filter_subject)} " <>
        "reason=#{inspect(reason)}"

    metadata = [
      consumer: name,
      durable: durable_name,
      stream: stream_name,
      filter_subject: filter_subject,
      reason: inspect(reason)
    ]

    case classification do
      :best_effort ->
        Logger.warning(
          "EventWriter skipping best-effort drain consumer " <> diagnostic,
          metadata
        )

      :required ->
        Logger.error(
          "Failed to initialize EventWriter durable consumer " <> diagnostic,
          metadata
        )
    end
  end

  defp setup_one_consumer(
         conn,
         config,
         stream,
         ack_wait_ns,
         max_ack_pending,
         max_deliver,
         default_pull_batch_size
       ) do
    # Drain streams set :durable_source_name to the pre-cutover stream name so
    # JetStream resumes the existing ACK cursor instead of creating a new durable.
    durable_key = Map.get(stream, :durable_source_name) || stream.name
    durable_name = Config.durable_name(config.consumer_name, durable_key)
    # Pull inbox stays unique per config entry (drain names differ from live).
    pull_subject = pull_subject(config.consumer_name, stream.name)
    pull_batch_size = Map.get(stream, :consumer_pull_batch_size, default_pull_batch_size)
    expected = expected_stream_name(stream)

    with {:ok, ensured} <-
           JetstreamConsumer.ensure_durable(
             conn,
             ensure_durable_opts(stream, durable_name, ack_wait_ns, max_ack_pending, max_deliver)
           ),
         :ok <- validate_resolved_stream(stream, ensured.stream_name, expected),
         {:ok, sid} <- Gnat.sub(conn, self(), pull_subject) do
      Logger.info("EventWriter JetStream consumer ready",
        stream: ensured.stream_name,
        durable: durable_name,
        filter_subject: stream.subject,
        pull_subject: pull_subject,
        pull_batch_size: pull_batch_size,
        sid: sid
      )

      {:ok,
       %{
         stream: ensured.stream_name,
         durable: durable_name,
         sid: sid,
         subject: stream.subject,
         pull_subject: pull_subject,
         pull_batch_size: pull_batch_size
       }}
    else
      {:error, reason} ->
        {:error, {stream.name, reason}}
    end
  end

  defp validate_resolved_stream(stream, resolved, expected) do
    if Config.flow_stream?(stream) and resolved != expected and
         Map.get(stream, :allow_stream_fallback, false) == false do
      {:error, {:unexpected_stream, expected: expected, resolved: resolved}}
    else
      :ok
    end
  end

  defp safe_unsub(conn, sid) when is_integer(sid) do
    Gnat.unsub(conn, sid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_unsub(_conn, _sid), do: :ok

  # Unlink first so :kill/:shutdown does not take down the Producer GenServer.
  # Gnat.start_link/1 links the connection to the caller until setup succeeds.
  defp safe_stop_conn(conn) when is_pid(conn) do
    if Process.alive?(conn) do
      Process.unlink(conn)
      ref = Process.monitor(conn)
      Process.exit(conn, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^conn, _} -> :ok
      after
        1_000 ->
          Process.exit(conn, :kill)

          receive do
            {:DOWN, ^ref, :process, ^conn, _} -> :ok
          after
            200 -> :ok
          end
      end
    end

    :ok
  end

  defp safe_stop_conn(_), do: :ok

  @doc false
  # Test helper: same cleanup path used after partial consumer setup failure.
  def __safe_stop_conn_for_test__(conn), do: safe_stop_conn(conn)

  # Drains up to `demand` buffered messages, preserving FIFO order.
  # `pending_count` is kept in sync so the overflow guard never needs an O(n)
  # length/1.
  defp drain_pending_messages(%{demand: demand, pending_count: pending_count} = state)
       when demand <= 0 or pending_count == 0 do
    {[], state}
  end

  defp drain_pending_messages(state) do
    take = min(state.demand, state.pending_count)
    {to_send, remaining_queue} = queue_take(state.pending_messages, take, [])

    {to_send,
     %{
       state
       | pending_messages: remaining_queue,
         pending_count: state.pending_count - take,
         demand: state.demand - take
     }}
  end

  defp maybe_request_pull_messages({messages, state}) do
    {messages, request_pull_messages(state)}
  end

  defp request_pull_messages(%{connected: false} = state), do: state
  defp request_pull_messages(%{demand: demand} = state) when demand <= 0, do: state

  defp request_pull_messages(%{consumer_context: %{consumers: consumers}} = state) do
    budget =
      state.demand
      |> min(state.max_buffered - state.pending_count - state.pull_inflight)
      |> max(0)

    per_consumer_budget = fair_consumer_budget(budget, length(consumers))

    {requested, requested_by_subject, _remaining_budget} =
      Enum.reduce_while(consumers, {0, [], budget}, fn consumer,
                                                       {requested, requested_by_subject,
                                                        remaining} ->
        # One outstanding pull per reply subject at a time so long-poll
        # accounting cannot stack overlapping batch budgets.
        outstanding = Map.get(state.pull_inflight_by_subject, consumer.pull_subject, 0)

        batch_size =
          if outstanding > 0 do
            0
          else
            remaining
            |> min(per_consumer_budget)
            |> pull_request_batch_size(consumer.pull_batch_size)
          end

        if batch_size <= 0 do
          {:cont, {requested, requested_by_subject, remaining}}
        else
          request_next_messages(state.conn, consumer, batch_size, state)

          {:cont,
           {requested + batch_size, [{consumer.pull_subject, batch_size} | requested_by_subject],
            remaining - batch_size}}
        end
      end)

    if requested > 0 do
      EventWriterTelemetry.emit_pull_request(requested, state, %{
        consumer_count: length(consumers)
      })
    end

    record_pull_inflight(
      %{state | pull_inflight: state.pull_inflight + requested},
      requested_by_subject
    )
  end

  defp request_pull_messages(state), do: state

  @doc false
  @spec pull_request_batch_size(non_neg_integer(), pos_integer() | nil) :: non_neg_integer()
  def pull_request_batch_size(available, _pull_batch_size) when available <= 0, do: 0

  def pull_request_batch_size(available, pull_batch_size)
      when is_integer(pull_batch_size) and pull_batch_size > 0 do
    min(available, pull_batch_size)
  end

  def pull_request_batch_size(available, _pull_batch_size) do
    min(available, Config.default_consumer_pull_batch_size())
  end

  defp fair_consumer_budget(_budget, consumer_count) when consumer_count <= 0, do: 0
  defp fair_consumer_budget(budget, _consumer_count) when budget <= 0, do: 0
  defp fair_consumer_budget(budget, consumer_count), do: max(1, ceil(budget / consumer_count))

  defp queue_take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp queue_take(queue, remaining, acc) do
    case :queue.out(queue) do
      {{:value, value}, queue} -> queue_take(queue, remaining - 1, [value | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  defp schedule_fetch(%{config: %Config{pull_expires_ns: expires}} = _state)
       when is_integer(expires) and expires > 0 do
    Process.send_after(self(), :fetch, @long_poll_idle_interval)
  end

  defp schedule_fetch(_state) do
    Process.send_after(self(), :fetch, @fetch_interval)
  end

  defp pull_status_message?(%{body: body, topic: topic}, state) do
    body == "" and MapSet.member?(pull_subjects(state), topic)
  end

  defp pull_subjects(%{consumer_context: %{pull_subjects: pull_subjects}}), do: pull_subjects
  defp pull_subjects(%{pull_subjects: pull_subjects}), do: pull_subjects
  defp pull_subjects(_state), do: MapSet.new()

  defp request_next_messages(conn, consumer, batch_size, state) do
    opts =
      case pull_expires_ns(state) do
        expires when is_integer(expires) and expires > 0 ->
          # Demand-gated long-poll: JetStream holds the request until messages
          # arrive or expires elapses (empty status body), instead of no_wait churn.
          [batch: batch_size, expires: expires]

        _ ->
          [batch: batch_size, no_wait: true]
      end

    JetstreamConsumerApi.request_next_message(
      conn,
      consumer.stream,
      consumer.durable,
      consumer.pull_subject,
      nil,
      opts
    )
  end

  defp pull_expires_ns(%{config: %Config{pull_expires_ns: expires}})
       when is_integer(expires) and expires > 0, do: expires

  defp pull_expires_ns(_state), do: 0

  defp long_poll_mode?(state), do: pull_expires_ns(state) > 0

  # Data msgs use original subject on :topic; resolve pull inbox via Gnat :sid.
  defp pull_key_for_msg(%{sid: sid, topic: topic}, %{sid_to_pull_subject: map})
       when is_integer(sid) and is_map(map) and map_size(map) > 0 do
    Map.get(map, sid, topic)
  end

  defp pull_key_for_msg(%{topic: topic}, state) do
    # Status/empty replies use the pull inbox topic; unit tests omit :sid.
    if MapSet.member?(pull_subjects(state), topic) do
      topic
    else
      # Fall back: if only one consumer is outstanding, use its pull subject.
      case Map.keys(state.pull_inflight_by_subject || %{}) do
        [only] -> only
        _ -> topic
      end
    end
  end

  defp expected_stream_name(stream) do
    Config.jetstream_stream_name(stream)
  end

  defp ensure_durable_opts(stream, durable_name, ack_wait_ns, max_ack_pending, max_deliver) do
    flow? = Config.flow_stream?(stream)

    [
      stream_name: expected_stream_name(stream),
      consumer_name: durable_name,
      filter_subject: stream.subject,
      description: "EventWriter consumer for #{stream.name}",
      ack_policy: :explicit,
      ack_wait: Map.get(stream, :consumer_ack_wait_ns, ack_wait_ns),
      deliver_policy: Map.get(stream, :consumer_deliver_policy),
      deliver_policy_if_absent: Map.get(stream, :consumer_deliver_policy_if_absent),
      max_ack_pending: Map.get(stream, :consumer_max_ack_pending, max_ack_pending),
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
      allow_stream_fallback: Map.get(stream, :allow_stream_fallback, not flow?),
      # Flow-collector owns `flows` retention; EventWriter only merges subjects.
      reconcile_stream_shape: Map.get(stream, :reconcile_stream_shape, not flow?),
      # Legacy events drain consumers must not create/reshape the shared stream.
      ensure_stream: Map.get(stream, :ensure_stream, true)
    ]
  end

  defp record_pull_inflight(state, []), do: state

  defp record_pull_inflight(state, requested_by_subject) do
    now_ms = System.monotonic_time(:millisecond)

    by_subject =
      Enum.reduce(requested_by_subject, state.pull_inflight_by_subject, fn {pull_subject,
                                                                            batch_size},
                                                                           acc ->
        Map.update(acc, pull_subject, batch_size, &(&1 + batch_size))
      end)

    started_at =
      Enum.reduce(
        requested_by_subject,
        pull_inflight_started_at(state),
        fn {pull_subject, _batch_size}, acc ->
          Map.put_new(acc, pull_subject, now_ms)
        end
      )

    %{state | pull_inflight_by_subject: by_subject, pull_inflight_started_at: started_at}
  end

  # Decrement both the global counter and the per-pull-subject remaining budget
  # so long-poll accounting cannot double-subtract on a later status clear.
  defp decrement_pull_inflight(state, pull_subject) when is_binary(pull_subject) do
    remaining = Map.get(state.pull_inflight_by_subject, pull_subject, 0)

    {by_subject, started_at} =
      if remaining <= 1 do
        {Map.delete(state.pull_inflight_by_subject, pull_subject),
         Map.delete(pull_inflight_started_at(state), pull_subject)}
      else
        {Map.put(state.pull_inflight_by_subject, pull_subject, remaining - 1),
         pull_inflight_started_at(state)}
      end

    %{
      state
      | pull_inflight: max(state.pull_inflight - 1, 0),
        pull_inflight_by_subject: by_subject,
        pull_inflight_started_at: started_at
    }
  end

  defp clear_pull_inflight(state, pull_subject) do
    {cleared, by_subject} = Map.pop(state.pull_inflight_by_subject, pull_subject, 0)

    %{
      state
      | pull_inflight: max(state.pull_inflight - cleared, 0),
        pull_inflight_by_subject: by_subject,
        pull_inflight_started_at: Map.delete(pull_inflight_started_at(state), pull_subject)
    }
  end

  defp pull_inflight_started_at(%{pull_inflight_started_at: started}) when is_map(started),
    do: started

  defp pull_inflight_started_at(_state), do: %{}

  defp expire_stale_pulls(state, now_ms) when is_integer(now_ms) do
    timeout_ms = stale_pull_timeout_ms(state.config)

    state
    |> pull_inflight_started_at()
    |> Enum.reduce(state, fn {pull_subject, started_at}, acc ->
      age_ms = now_ms - started_at
      remaining = Map.get(acc.pull_inflight_by_subject, pull_subject, 0)

      if remaining > 0 and age_ms > timeout_ms do
        EventWriterTelemetry.emit_stale_pull(remaining, age_ms, pull_subject)

        Logger.warning(
          "EventWriter dropping stale JetStream pull inflight; re-arming consumer",
          pull_subject: pull_subject,
          expired_inflight: remaining,
          age_ms: age_ms,
          timeout_ms: timeout_ms
        )

        clear_pull_inflight(acc, pull_subject)
      else
        acc
      end
    end)
  end

  defp build_ack_fun(conn, reply_to) when is_binary(reply_to) and reply_to != "" do
    fn
      :ack ->
        # For JetStream, acknowledge by sending +ACK to the reply subject
        safe_ack_publish(conn, reply_to, "+ACK")

      :nack ->
        # Send -NAK to trigger redelivery
        safe_ack_publish(conn, reply_to, "-NAK")

      :term ->
        # Terminal ACK prevents JetStream from redelivering a known poison message.
        safe_ack_publish(conn, reply_to, "+TERM")
    end
  end

  defp build_ack_fun(_conn, _reply_to) do
    # No reply_to means we can't ack (core NATS, not JetStream)
    fn _ -> :ok end
  end

  defp safe_ack_publish(conn, reply_to, payload) when is_binary(reply_to) and reply_to != "" do
    conn_ref = resolve_conn_ref(conn)

    cond do
      is_nil(conn_ref) ->
        {:error, :nats_connection_not_available}

      is_pid(conn_ref) and not Process.alive?(conn_ref) ->
        {:error, :nats_connection_not_alive}

      true ->
        try do
          Gnat.pub(conn_ref, reply_to, payload)
        rescue
          error ->
            {:error, error}
        catch
          :exit, reason ->
            {:error, {:exit, reason}}

          kind, reason ->
            {:error, {kind, reason}}
        end
    end
  end

  defp safe_ack_publish(_conn, _reply_to, _payload), do: {:error, :invalid_ack_payload}

  defp resolve_conn_ref(conn) when is_pid(conn), do: conn

  defp resolve_conn_ref(conn) when is_atom(conn) do
    Process.whereis(conn)
  end

  defp resolve_conn_ref(conn), do: conn

  defp pull_subject(base, stream_name) do
    suffix =
      stream_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "_INBOX.serviceradar.event_writer.pull.#{base}.#{suffix}"
  end

  defp extract_original_subject(topic, headers) do
    find_header_value(headers, "nats-subject") ||
      find_header_value(headers, "nats-subject-token") ||
      topic
  end

  defp find_header_value(headers, key) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if normalize_header_key(k) == key do
        normalize_header_value(v)
      end
    end)
  end

  defp find_header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} ->
        if normalize_header_key(k) == key do
          normalize_header_value(v)
        end

      _ ->
        nil
    end)
  end

  defp find_header_value(_headers, _key), do: nil

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_header_key(key) when is_list(key), do: key |> to_string() |> String.downcase()
  defp normalize_header_key(_), do: ""

  defp normalize_header_value(value) when is_binary(value), do: value

  defp normalize_header_value(value) when is_list(value) do
    case value do
      [first | _] when is_binary(first) -> first
      [first | _] when is_list(first) -> to_string(first)
      _ -> to_string(value)
    end
  rescue
    _ -> nil
  end

  defp normalize_header_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_header_value(value), do: to_string(value)

  defp max_deliver_for(%Config{} = config, jetstream_ack, subject) do
    default = config.max_deliver || Config.default_max_deliver()

    config.streams
    |> Enum.find(&stream_matches_message?(&1, jetstream_ack, subject))
    |> case do
      %{consumer_max_deliver: max_deliver} when is_integer(max_deliver) and max_deliver > 0 ->
        max_deliver

      _ ->
        default
    end
  end

  defp stream_matches_message?(stream, %{stream: ack_stream}, subject)
       when is_binary(ack_stream) do
    stream_name = Map.get(stream, :stream_name) || Map.get(stream, :name)
    subject_filter = Map.get(stream, :subject)

    is_binary(stream_name) and stream_name == ack_stream and
      (not is_binary(subject) or subject_covers?(subject_filter, subject))
  end

  defp stream_matches_message?(stream, _ack, subject) when is_binary(subject) do
    stream
    |> Map.get(:subject)
    |> subject_covers?(subject)
  end

  defp stream_matches_message?(_stream, _ack, _subject), do: false

  defp subject_covers?(candidate, subject) when is_binary(candidate) and is_binary(subject) do
    covers_tokens?(String.split(candidate, "."), String.split(subject, "."))
  end

  defp subject_covers?(_candidate, _subject), do: false

  defp covers_tokens?([""], []), do: true
  defp covers_tokens?([">"], [_subject | _subject_rest]), do: true
  defp covers_tokens?([">"], []), do: false
  defp covers_tokens?([], []), do: true
  defp covers_tokens?([], _subject_tokens), do: false
  defp covers_tokens?(_candidate_tokens, []), do: false

  defp covers_tokens?(["*" | candidate_rest], [_subject | subject_rest]) do
    covers_tokens?(candidate_rest, subject_rest)
  end

  defp covers_tokens?([candidate | candidate_rest], [candidate | subject_rest]) do
    covers_tokens?(candidate_rest, subject_rest)
  end

  defp covers_tokens?(_candidate_tokens, _subject_tokens), do: false
end
