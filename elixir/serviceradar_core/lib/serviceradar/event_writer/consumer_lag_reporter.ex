defmodule ServiceRadar.EventWriter.ConsumerLagReporter do
  @moduledoc """
  Periodically emits JetStream durable consumer backlog telemetry.

  The EventWriter producer exposes local Broadway/backpressure state. This
  process emits the server-side view so operators can distinguish a controlled
  pull-consumer slowdown from an accumulating JetStream backlog. It also polls
  each consumer's JetStream stream once per interval. For flow and edge-record
  consumers it combines MaxBytes/current bytes plus MaxAge/oldest
  retained-message age into the retention-risk telemetry event.

  The stream's first sequence also shows a durable losing messages it never
  received (`ServiceRadar.EventWriter.Telemetry.expired_before_delivery/2`):
  reported as `expired_before_delivery`, alerted on, and logged once per stream and
  durable when it starts losing messages and once when it stops.
  """

  use GenServer

  alias Gnat.Jetstream.API.Consumer
  alias Gnat.Jetstream.API.Stream
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.NATS.Connection

  require Logger

  defstruct [:config, :interval_ms, :consumers, expiring: MapSet.new()]

  @type consumer_ref :: %{
          required(:stream) => String.t(),
          required(:durable) => String.t(),
          required(:subject_class) => String.t()
        }

  @doc """
  Starts the lag reporter for an EventWriter config.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc false
  @spec consumer_refs(Config.t()) :: [consumer_ref()]
  def consumer_refs(%Config{} = config) do
    Enum.map(config.streams, fn stream ->
      stream_name = Map.get(stream, :stream_name) || stream.name

      durable_key = Map.get(stream, :durable_source_name) || stream.name

      %{
        stream: stream_name,
        durable: Config.durable_name(config.consumer_name, durable_key),
        subject_class: EventWriterTelemetry.subject_class(stream.subject)
      }
    end)
  end

  @doc false
  # Each stream once, however many consumers read it. Every consumer's stream is polled: its
  # first sequence is what shows messages expiring before delivery, and the security-quarantine
  # and dead-letter streams report their depth (`stream_bytes`) only here, because their
  # consumers write nothing and consumer lag says nothing about how many records they hold.
  @spec polled_stream_names([consumer_ref()]) :: [String.t()]
  def polled_stream_names(consumers) when is_list(consumers) do
    consumers
    |> Enum.map(& &1.stream)
    |> Enum.uniq()
  end

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{
      config: config,
      interval_ms: poll_interval_ms(config),
      consumers: consumer_refs(config)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    schedule_next_poll(state.interval_ms)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll(%__MODULE__{consumers: []} = state), do: state

  defp poll(%__MODULE__{consumers: consumers} = state) do
    case Connection.get() do
      {:ok, conn} ->
        stream_info = poll_streams(conn, consumers)

        Enum.reduce(consumers, state, fn consumer, acc ->
          poll_consumer(conn, consumer, stream_info, acc)
        end)

      {:error, reason} ->
        Enum.each(consumers, fn consumer ->
          EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
        end)

        state
    end
  end

  defp poll_consumer(conn, consumer, stream_info, state) do
    case safe_consumer_info(conn, consumer.stream, consumer.durable) do
      {:ok, info} ->
        report_consumer(state, consumer, info, stream_info)

      {:error, reason} ->
        Logger.debug("Failed to poll EventWriter JetStream consumer state",
          stream: consumer.stream,
          durable: consumer.durable,
          reason: inspect(reason)
        )

        EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
        state
    end
  end

  @doc false
  # Emits one consumer's state from its INFO and the polled stream INFO by stream name, and
  # returns the reporter state with that durable's loss flag updated.
  @spec report_consumer(%__MODULE__{}, consumer_ref(), map(), %{
          optional(String.t()) => map() | nil
        }) ::
          %__MODULE__{}
  def report_consumer(%__MODULE__{} = state, consumer, info, stream_info) do
    expired =
      EventWriterTelemetry.expired_before_delivery(info, Map.get(stream_info, consumer.stream))

    EventWriterTelemetry.emit_consumer_state(
      info,
      retention_info_for_consumer(consumer, stream_info),
      expired,
      consumer
    )

    track_expiry(state, consumer, expired)
  end

  # Classes whose stream retention state feeds the retention gauges and risk level. Every other
  # class reads its stream only for the first sequence: a MaxAge stream's oldest message sits
  # near MaxAge for its whole life, so its age would mark any in-flight ack as critical risk.
  # The security-quarantine and dead-letter classes are here so their stream depth
  # (`stream_bytes`) is reported: their consumers write nothing, so consumer lag says nothing
  # about how many records those streams hold.
  @retention_classes [
    "flows",
    "edge_record",
    "edge_record_audit",
    "edge_record_quarantine",
    "edge_record_dlq"
  ]

  defp retention_info_for_consumer(%{subject_class: class, stream: stream}, stream_info)
       when class in @retention_classes,
       do: Map.get(stream_info, stream)

  defp retention_info_for_consumer(_consumer, _stream_info), do: nil

  # Logs a durable's loss once when it starts and once when it ends; the gauge carries it in
  # between. A durable name is unique only within its stream (a drain reuses the live name on
  # another stream), so the flag is keyed by both. Returns the state with the flag updated.
  defp track_expiry(%__MODULE__{expiring: expiring} = state, consumer, expired) do
    key = {consumer.stream, consumer.durable}
    flagged? = MapSet.member?(expiring, key)

    cond do
      expired > 0 and not flagged? ->
        Logger.error(
          "EventWriter durable is losing messages: its stream discarded them before delivery",
          stream: consumer.stream,
          durable: consumer.durable,
          expired_sequences: expired
        )

        %{state | expiring: MapSet.put(expiring, key)}

      expired == 0 and flagged? ->
        Logger.info("EventWriter durable no longer trails its stream's first sequence",
          stream: consumer.stream,
          durable: consumer.durable
        )

        %{state | expiring: MapSet.delete(expiring, key)}

      true ->
        state
    end
  end

  defp poll_streams(conn, consumers) do
    consumers
    |> polled_stream_names()
    |> Map.new(fn stream ->
      case safe_stream_info(conn, stream) do
        {:ok, info} ->
          {stream, info}

        {:error, reason} ->
          Logger.debug("Failed to poll EventWriter JetStream stream retention state",
            stream: stream,
            reason: inspect(reason)
          )

          {stream, nil}
      end
    end)
  end

  defp safe_consumer_info(conn, stream, durable) do
    Consumer.info(conn, stream, durable)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_stream_info(conn, stream) do
    Stream.info(conn, stream)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp schedule_next_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp poll_interval_ms(%Config{consumer_lag_poll_interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    interval_ms
  end

  defp poll_interval_ms(%Config{}), do: Config.default_consumer_lag_poll_interval_ms()
end
