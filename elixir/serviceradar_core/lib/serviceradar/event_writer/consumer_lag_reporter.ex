defmodule ServiceRadar.EventWriter.ConsumerLagReporter do
  @moduledoc """
  Periodically emits JetStream durable consumer backlog telemetry.

  The EventWriter producer exposes local Broadway/backpressure state. This
  process emits the server-side view so operators can distinguish a controlled
  pull-consumer slowdown from an accumulating JetStream backlog. For flow
  consumers it also polls each unique JetStream stream once per interval and
  combines MaxBytes/current bytes plus MaxAge/oldest retained-message age into
  the retention-risk telemetry event.
  """

  use GenServer

  alias Gnat.Jetstream.API.Consumer
  alias Gnat.Jetstream.API.Stream
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.NATS.Connection

  require Logger

  defstruct [:config, :interval_ms, :consumers]

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
  @spec retention_stream_names([consumer_ref()]) :: [String.t()]
  def retention_stream_names(consumers) when is_list(consumers) do
    consumers
    |> Enum.filter(&(&1.subject_class == "flows"))
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
    poll(state)
    schedule_next_poll(state.interval_ms)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll(%__MODULE__{consumers: []}), do: :ok

  defp poll(%__MODULE__{consumers: consumers}) do
    case Connection.get() do
      {:ok, conn} ->
        stream_info = poll_flow_streams(conn, consumers)
        Enum.each(consumers, &poll_consumer(conn, &1, stream_info))

      {:error, reason} ->
        Enum.each(consumers, fn consumer ->
          EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
        end)
    end
  end

  defp poll_consumer(conn, consumer, stream_info) do
    case safe_consumer_info(conn, consumer.stream, consumer.durable) do
      {:ok, info} ->
        EventWriterTelemetry.emit_consumer_state(
          info,
          retention_info_for_consumer(consumer, stream_info),
          consumer
        )

      {:error, reason} ->
        Logger.debug("Failed to poll EventWriter JetStream consumer state",
          stream: consumer.stream,
          durable: consumer.durable,
          reason: inspect(reason)
        )

        EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
    end
  end

  defp retention_info_for_consumer(%{subject_class: "flows", stream: stream}, stream_info),
    do: Map.get(stream_info, stream)

  defp retention_info_for_consumer(_consumer, _stream_info), do: nil

  defp poll_flow_streams(conn, consumers) do
    consumers
    |> retention_stream_names()
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
