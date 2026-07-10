defmodule ServiceRadar.EventWriter.ConsumerLagReporter do
  @moduledoc """
  Periodically emits JetStream durable consumer backlog telemetry.

  The EventWriter producer exposes local Broadway/backpressure state. This
  process emits the server-side view so operators can distinguish a controlled
  pull-consumer slowdown from an accumulating JetStream backlog.
  """

  use GenServer

  alias Gnat.Jetstream.API.Consumer
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

      %{
        stream: stream_name,
        durable: Config.durable_name(config.consumer_name, stream.name),
        subject_class: EventWriterTelemetry.subject_class(stream.subject)
      }
    end)
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
        Enum.each(consumers, &poll_consumer(conn, &1))

      {:error, reason} ->
        Enum.each(consumers, fn consumer ->
          EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
        end)
    end
  end

  defp poll_consumer(conn, consumer) do
    case safe_consumer_info(conn, consumer.stream, consumer.durable) do
      {:ok, info} ->
        EventWriterTelemetry.emit_consumer_state(info, consumer)

      {:error, reason} ->
        Logger.debug("Failed to poll EventWriter JetStream consumer state",
          stream: consumer.stream,
          durable: consumer.durable,
          reason: inspect(reason)
        )

        EventWriterTelemetry.emit_consumer_state_error(reason, consumer)
    end
  end

  defp safe_consumer_info(conn, stream, durable) do
    Consumer.info(conn, stream, durable)
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
