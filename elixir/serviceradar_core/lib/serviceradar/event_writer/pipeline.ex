defmodule ServiceRadar.EventWriter.Pipeline do
  @moduledoc """
  Broadway pipeline for processing NATS JetStream messages.

  This pipeline consumes messages from multiple NATS JetStream streams,
  batches them, and writes them to CNPG hypertables via dedicated processors.

  ## Message Flow

  1. Producer fetches messages from NATS JetStream
  2. Messages are routed to batchers based on subject pattern
  3. Batchers collect messages until batch_size or batch_timeout
  4. Processors transform and insert batches into database
  5. Messages are acknowledged on success, NACK'd on failure

  ## Back-pressure

  Broadway provides automatic back-pressure handling. If the database
  cannot keep up with incoming messages, the producer will slow down
  fetching from NATS JetStream.
  """

  use Broadway

  require Logger

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config

  @doc """
  Starts the Broadway pipeline.
  """
  def start_link(%Config{} = config) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {ServiceRadar.EventWriter.Producer, config},
        transformer: {__MODULE__, :transform, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 4]
      ],
      batchers: build_batchers(config)
    )
  end

  @doc """
  Transforms messages from the producer into Broadway messages.
  """
  def transform(event, _opts) do
    %Message{
      data: event.data,
      metadata: event.metadata,
      acknowledger: {__MODULE__, :ack_ref, event.ack_data}
    }
  end

  @doc """
  Acknowledges processed messages.
  """
  def ack(:ack_ref, successful, failed) do
    # Acknowledge successful messages
    Enum.each(successful, fn %{acknowledger: {_, _, ack_data}} ->
      if ack_data[:ack_fun] do
        ack_data.ack_fun.(:ack)
      end
    end)

    # NACK failed messages for retry
    Enum.each(failed, fn %{acknowledger: {_, _, ack_data}} ->
      if ack_data[:ack_fun] do
        ack_data.ack_fun.(:nack)
      end
    end)

    :ok
  end

  @impl true
  def handle_message(_processor, %Message{} = message, _context) do
    # Route message to appropriate batcher based on subject
    batcher = determine_batcher(message.metadata[:subject])

    message
    |> Message.put_batcher(batcher)
  end

  @impl true
  def handle_batch(batcher, messages, batch_info, _context) do
    processor = get_processor(batcher)
    start_time = System.monotonic_time(:millisecond)

    result = processor.process_batch(messages)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, count} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :batch_processed],
          %{count: count, duration: duration, batch_size: length(messages)},
          %{stream: batcher, processor: processor, batch_key: batch_info.batch_key}
        )

        Logger.debug("Processed batch",
          batcher: batcher,
          count: count,
          duration_ms: duration
        )

        messages

      {:error, reason} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :batch_failed],
          %{count: length(messages)},
          %{stream: batcher, processor: processor, reason: inspect(reason)}
        )

        Logger.error("Batch processing failed",
          batcher: batcher,
          reason: inspect(reason),
          message_count: length(messages)
        )

        # Mark all messages as failed
        Enum.map(messages, &Message.failed(&1, reason))
    end
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("Message failed",
        subject: message.metadata[:subject],
        reason: inspect(message.status)
      )
    end)

    messages
  end

  # Private functions

  defp build_batchers(config) do
    config.streams
    |> Enum.map(fn stream ->
      batcher_name = stream_to_batcher_name(stream.name)

      {batcher_name,
       [
         batch_size: stream[:batch_size] || config.batch_size,
         batch_timeout: stream[:batch_timeout] || config.batch_timeout
       ]}
    end)
    |> Keyword.new()
  end

  defp determine_batcher(subject) when is_binary(subject) do
    cond do
      String.starts_with?(subject, "otel.metrics") -> :otel_metrics
      String.starts_with?(subject, "otel.traces") -> :otel_traces
      String.starts_with?(subject, "logs.") -> :logs
      String.starts_with?(subject, "telemetry.") -> :telemetry
      String.starts_with?(subject, "sweep.") -> :sweep
      String.starts_with?(subject, "netflow.") -> :netflow
      true -> :default
    end
  end

  defp determine_batcher(_), do: :default

  defp get_processor(:otel_metrics), do: ServiceRadar.EventWriter.Processors.OtelMetrics
  defp get_processor(:otel_traces), do: ServiceRadar.EventWriter.Processors.OtelTraces
  defp get_processor(:logs), do: ServiceRadar.EventWriter.Processors.Logs
  defp get_processor(:telemetry), do: ServiceRadar.EventWriter.Processors.Telemetry
  defp get_processor(:sweep), do: ServiceRadar.EventWriter.Processors.Sweep
  defp get_processor(:netflow), do: ServiceRadar.EventWriter.Processors.NetFlow
  defp get_processor(_), do: ServiceRadar.EventWriter.Processors.Default

  defp stream_to_batcher_name(stream_name) do
    stream_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.to_atom()
  end
end
