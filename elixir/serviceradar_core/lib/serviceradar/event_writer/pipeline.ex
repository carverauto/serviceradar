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
    subject = message.metadata[:subject]

    # Subjects are unprefixed in single-deployment deployments.
    base_subject = normalize_subject(subject)

    # Route message to appropriate batcher based on base subject
    batcher = determine_batcher(base_subject)

    # Add base_subject to metadata for batch processing
    updated_metadata = Map.put(message.metadata, :base_subject, base_subject)

    message
    |> Map.put(:metadata, updated_metadata)
    |> Message.put_batcher(batcher)
  end

  defp normalize_subject(subject) when is_binary(subject), do: subject
  defp normalize_subject(_), do: ""

  # DB connection's search_path determines the schema
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
    stream_batchers =
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

    if Keyword.has_key?(stream_batchers, :default) do
      stream_batchers
    else
      Keyword.put(stream_batchers, :default,
        batch_size: config.batch_size,
        batch_timeout: config.batch_timeout
      )
    end
  end

  defp determine_batcher(subject) when is_binary(subject) do
    Enum.find_value(batcher_rules(), :default, fn {batcher, matcher} ->
      if matcher.(subject), do: batcher, else: nil
    end)
  end

  defp determine_batcher(_), do: :default

  defp batcher_rules do
    [
      {:default, &ignore_logs_subject?/1},
      {:logs, &log_subject?/1},
      {:default, &ignore_events_subject?/1},
      {:bmp_causal, &bmp_causal_subject?/1},
      {:arancini_causal, &arancini_causal_subject?/1},
      {:siem_causal, &siem_causal_subject?/1},
      {:otel_metrics, &String.starts_with?(&1, "otel.metrics")},
      {:otel_traces, &String.starts_with?(&1, "otel.traces")},
      {:logs, &String.starts_with?(&1, "logs.")},
      {:events, &String.starts_with?(&1, "events.")},
      {:telemetry, &String.starts_with?(&1, "telemetry.")},
      {:sflow_raw, &String.starts_with?(&1, "flows.raw.sflow")},
      {:netflow_raw, &String.starts_with?(&1, "flows.raw.netflow")},
      {:netflow, &String.starts_with?(&1, "netflow.")}
    ]
  end

  defp ignore_logs_subject?(subject) do
    subject == "logs.syslog" or subject == "logs.snmp" or subject == "logs.otel"
  end

  defp log_subject?(subject) do
    String.starts_with?(subject, "logs.otel") or
      String.starts_with?(subject, "logs.syslog.processed") or
      String.starts_with?(subject, "logs.snmp.processed")
  end

  defp ignore_events_subject?(subject) do
    String.starts_with?(subject, "events.syslog") or
      String.starts_with?(subject, "events.snmp") or
      String.starts_with?(subject, "snmp.traps")
  end

  defp bmp_causal_subject?(subject),
    do:
      subject == "bmp.events" or
        String.starts_with?(subject, "bmp.events.") or
        subject == "signals.causal" or
        String.starts_with?(subject, "signals.causal.")

  defp arancini_causal_subject?(subject),
    do: subject == "arancini.updates" or String.starts_with?(subject, "arancini.updates.")

  defp siem_causal_subject?(subject),
    do: subject == "siem.events" or String.starts_with?(subject, "siem.events.")

  defp get_processor(:otel_metrics), do: ServiceRadar.EventWriter.Processors.OtelMetrics
  defp get_processor(:otel_traces), do: ServiceRadar.EventWriter.Processors.OtelTraces
  defp get_processor(:events), do: ServiceRadar.EventWriter.Processors.Events
  defp get_processor(:bmp_causal), do: ServiceRadar.EventWriter.Processors.CausalSignals
  defp get_processor(:arancini_causal), do: ServiceRadar.EventWriter.Processors.CausalSignals
  defp get_processor(:siem_causal), do: ServiceRadar.EventWriter.Processors.CausalSignals
  defp get_processor(:causal_signals), do: ServiceRadar.EventWriter.Processors.CausalSignals
  defp get_processor(:logs), do: ServiceRadar.EventWriter.Processors.Logs
  defp get_processor(:telemetry), do: ServiceRadar.EventWriter.Processors.Telemetry
  defp get_processor(:sflow_raw), do: ServiceRadar.EventWriter.Processors.Flows
  defp get_processor(:netflow_raw), do: ServiceRadar.EventWriter.Processors.Flows
  defp get_processor(:netflow), do: ServiceRadar.EventWriter.Processors.Flows
  defp get_processor(_), do: ServiceRadar.EventWriter.Processors.Default

  defp stream_to_batcher_name(stream_name) do
    stream_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.to_atom()
  end
end
