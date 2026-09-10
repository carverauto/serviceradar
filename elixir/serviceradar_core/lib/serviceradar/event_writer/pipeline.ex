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

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.Flows
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.EventWriter.Processors.PowerDNS
  alias ServiceRadar.EventWriter.Processors.Telemetry
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.Otel
  alias ServiceRadar.Otel.Propagation

  require Logger

  # Maximum number of upstream trace contexts linked onto a batch span.
  @max_batch_links 8
  @tracer_cache_key {__MODULE__, :batch_tracer}

  @doc """
  Starts the Broadway pipeline.

  Options:
  - `:name` — Broadway process name (default `__MODULE__`). Use a distinct name
    for the dedicated flow pipeline so GenStage demand is not shared.
  """
  def start_link(%Config{} = config, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Broadway.start_link(__MODULE__,
      name: name,
      producer: [
        module: {ServiceRadar.EventWriter.Producer, config},
        transformer: {__MODULE__, :transform, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: processor_concurrency(config)]
      ],
      batchers: build_batchers(config)
    )
  end

  def child_spec({%Config{} = config, opts}) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [config, opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  def child_spec(%Config{} = config) do
    child_spec({config, []})
  end

  # Processor concurrency was 4 in the Go->Elixir migration, which under-utilized
  # the pipeline. Raised to a configurable default (Config.processor_concurrency,
  # default 10) so DB writes parallelize. The producer's bounded in-flight keeps
  # this from translating into unbounded memory.
  defp processor_concurrency(%Config{processor_concurrency: concurrency})
       when is_integer(concurrency) and concurrency > 0, do: concurrency

  defp processor_concurrency(%Config{}), do: Config.default_processor_concurrency()

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
    Enum.each(successful, &ack_message(&1, :ack))

    # Retry failed messages until their final JetStream delivery, then terminally
    # ack and emit a dead-letter signal so operators see poison messages before
    # the server discards them at max_deliver.
    Enum.each(failed, &ack_failed_message/1)

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
    subject = batch_subject(messages)

    with_batch_span(subject, messages, fn ->
      run_batch(batcher, messages, batch_info)
    end)
  end

  @doc false
  # Wraps non-telemetry batch processing in a consumer span carrying span
  # links to the upstream trace contexts found in message headers.
  #
  # Telemetry subjects (otel.>, logs.>, including otel.metrics.>) are
  # explicitly excluded: creating a span while persisting spans/logs/metrics
  # would emit telemetry about telemetry and self-amplify the signal stream.
  def with_batch_span(subject, messages, fun) when is_function(fun, 0) do
    if telemetry_subject?(subject) do
      fun.()
    else
      with_current_tracer_span(
        "event_writer.process_batch",
        %{
          kind: :consumer,
          links: batch_links(messages),
          attributes: %{
            "messaging.system" => "nats",
            "messaging.operation.name" => "process",
            "messaging.destination.name" => subject,
            "messaging.batch.message_count" => length(messages)
          }
        },
        fun
      )
    end
  end

  defp with_current_tracer_span(name, start_opts, fun) do
    Otel.span_with_tracer(current_tracer(), name, start_opts, fun)
  end

  # Application tracers survive SDK restarts in persistent_term. Key the hot-path
  # cache by provider PID so a restarted provider is queried exactly once per worker.
  defp current_tracer do
    provider = Otel.provider_identity()

    case Process.get(@tracer_cache_key) do
      {^provider, tracer} ->
        tracer

      _stale_or_missing ->
        {resolved_provider, tracer} = Otel.tracer_snapshot(__MODULE__, provider)
        Process.put(@tracer_cache_key, {resolved_provider, tracer})
        tracer
    end
  end

  @doc false
  # True for subjects carrying telemetry payloads; the batch consumer span must
  # never be created for these.
  def telemetry_subject?(subject) when is_binary(subject) do
    String.starts_with?(subject, "otel.") or String.starts_with?(subject, "logs.") or
      String.starts_with?(subject, "metrics.")
  end

  def telemetry_subject?(_subject), do: false

  @doc false
  def configured_batcher_names(%Config{} = config) do
    config
    |> build_batchers()
    |> Keyword.keys()
  end

  @doc false
  # Builds span links from the W3C trace-context headers of up to
  # @max_batch_links distinct messages (deduplicated by trace/span id).
  def batch_links(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while([], fn message, acc ->
      if length(acc) >= @max_batch_links do
        {:halt, acc}
      else
        case Propagation.extract_link(message_headers(message)) do
          nil -> {:cont, acc}
          link -> {:cont, put_new_link(acc, link)}
        end
      end
    end)
    |> Enum.reverse()
  end

  def batch_links(_messages), do: []

  defp put_new_link(links, %{trace_id: trace_id, span_id: span_id} = link) do
    duplicate? =
      Enum.any?(links, fn %{trace_id: existing_trace, span_id: existing_span} ->
        existing_trace == trace_id and existing_span == span_id
      end)

    if duplicate?, do: links, else: [link | links]
  end

  defp put_new_link(links, _link), do: links

  defp message_headers(%{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :headers)

  defp message_headers(_message), do: nil

  defp batch_subject([message | _rest]) do
    metadata = Map.get(message, :metadata) || %{}
    metadata[:base_subject] || normalize_subject(metadata[:subject])
  end

  defp batch_subject(_messages), do: ""

  defp run_batch(batcher, messages, batch_info) do
    processor = get_processor(batcher)
    start_time = System.monotonic_time()

    result = processor.process_batch(messages)

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:ok, count} ->
        EventWriterTelemetry.emit_batch(:ok, messages, count, duration, %{
          stream: batcher,
          processor: processor
        })

        :telemetry.execute(
          [:serviceradar, :event_writer, :batch_processed],
          %{count: count, duration: duration_ms, batch_size: length(messages)},
          %{stream: batcher, processor: processor, batch_key: batch_info.batch_key}
        )

        Logger.debug("Processed batch",
          batcher: batcher,
          count: count,
          duration_ms: duration_ms
        )

        messages

      {:error, reason} ->
        EventWriterTelemetry.emit_batch(:error, messages, length(messages), duration, %{
          stream: batcher,
          processor: processor
        })

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

        # No-op when no batch span is active (telemetry subjects).
        Otel.set_error(reason)

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

  defp ack_failed_message(message) do
    if terminal_delivery?(message) do
      emit_dead_letter(message)
      ack_message(message, :term)
    else
      ack_message(message, :nack)
    end
  end

  defp terminal_delivery?(%{metadata: metadata}) when is_map(metadata) do
    with %{delivery_count: delivery_count} <- metadata[:jetstream_ack],
         max_deliver when is_integer(max_deliver) and max_deliver > 0 <- metadata[:max_deliver] do
      delivery_count >= max_deliver
    else
      _ -> false
    end
  end

  defp terminal_delivery?(_message), do: false

  defp emit_dead_letter(%{metadata: metadata, status: status}) do
    ack = metadata[:jetstream_ack] || %{}

    EventWriterTelemetry.emit_dead_letter(%{
      subject: metadata[:subject],
      stream: ack[:stream],
      consumer: ack[:consumer],
      delivery_count: ack[:delivery_count],
      max_deliver: metadata[:max_deliver],
      reason_class: reason_class(status)
    })

    Logger.error("EventWriter message reached terminal JetStream delivery",
      subject: metadata[:subject],
      stream: ack[:stream],
      consumer: ack[:consumer],
      delivery_count: ack[:delivery_count],
      max_deliver: metadata[:max_deliver],
      reason: inspect(status)
    )
  end

  defp reason_class(nil), do: "error"
  defp reason_class({:failed, reason}), do: reason_class(reason)
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%_{} = reason), do: reason.__struct__ |> Module.split() |> List.last()
  defp reason_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "error"

  defp build_batchers(config) do
    # Collapse all raw-flow streams (live + drain + extras) onto :flows_raw so
    # the batcher set matches batcher_rules/0 routing (flows.raw.* → :flows_raw).
    stream_batchers =
      Enum.reduce(config.streams, [], fn stream, acc ->
        batcher_name =
          if Config.flow_stream?(stream) do
            :flows_raw
          else
            stream_to_batcher_name(stream.name)
          end

        if Keyword.has_key?(acc, batcher_name) do
          acc
        else
          Keyword.put(acc, batcher_name,
            batch_size: stream[:batch_size] || config.batch_size,
            batch_timeout: stream[:batch_timeout] || config.batch_timeout
          )
        end
      end)

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
      if matcher.(subject), do: batcher
    end)
  end

  defp determine_batcher(_), do: :default

  defp ack_message(%{acknowledger: {_, _, ack_data}} = message, action) do
    case ack_data[:ack_fun] do
      ack_fun when is_function(ack_fun, 1) ->
        ack_started = System.monotonic_time()

        case safe_invoke_ack(ack_fun, action) do
          :ok ->
            EventWriterTelemetry.emit_ack(
              action,
              :ok,
              ack_latency(message, ack_started),
              message.metadata[:subject]
            )

            :ok

          {:error, reason} ->
            EventWriterTelemetry.emit_ack(
              action,
              :error,
              ack_latency(message, ack_started),
              message.metadata[:subject]
            )

            Logger.debug("Failed to publish EventWriter ack",
              action: action,
              reason: inspect(reason),
              subject: message.metadata[:subject],
              reply_to: message.metadata[:reply_to]
            )
        end

      _ ->
        :ok
    end
  end

  defp ack_message(_message, _action), do: :ok

  defp ack_latency(%{metadata: %{received_monotonic: received_at}}, _ack_started)
       when is_integer(received_at) do
    max(System.monotonic_time() - received_at, 0)
  end

  defp ack_latency(_message, ack_started), do: max(System.monotonic_time() - ack_started, 0)

  defp safe_invoke_ack(ack_fun, action) when is_function(ack_fun, 1) do
    case ack_fun.(action) do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  rescue
    error ->
      {:error, error}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}

    kind, reason ->
      {:error, {kind, reason}}
  end

  defp batcher_rules do
    [
      {:logs, &log_subject?/1},
      {:default, &ignore_events_subject?/1},
      {:analytics_predictions, &analytics_predictions_subject?/1},
      {:bmp_causal, &bmp_or_analytics_subject?/1},
      {:arancini_causal, &arancini_causal_subject?/1},
      {:siem_causal, &siem_causal_subject?/1},
      {:pdns_ocsf, &pdns_ocsf_subject?/1},
      {:falco, &falco_subject?/1},
      {:trivy, &trivy_subject?/1},
      {:k8s_nodes, &k8s_nodes_subject?/1},
      {:k8s_inventory, &k8s_inventory_subject?/1},
      {:otel_metrics, &String.starts_with?(&1, "otel.metrics")},
      {:otel_traces, &String.starts_with?(&1, "otel.traces")},
      {:metrics, &String.starts_with?(&1, "metrics.")},
      {:logs, &String.starts_with?(&1, "logs.")},
      {:events, &String.starts_with?(&1, "events.")},
      # MUST precede the generic :telemetry rule below -- both match a
      # "telemetry." prefix, and find_value/2 takes the first match.
      {:edge_record, &String.starts_with?(&1, "telemetry.edge-record.")},
      {:telemetry, &String.starts_with?(&1, "telemetry.")},
      # Catch-all before specific prefixes are unnecessary: every raw-flow
      # subject (netflow/sflow/ipfix/extensions) must hit Processors.Flows.
      # flow.host-slice.* is intentionally excluded (attribution joining is
      # currently unsupported / out of scope for this pipeline).
      {:flows_raw, &String.starts_with?(&1, "flows.raw.")}
    ]
  end

  defp log_subject?(subject) do
    String.starts_with?(subject, "logs.otel") or
      subject == "logs.syslog" or
      String.starts_with?(subject, "logs.syslog.processed") or
      subject == "logs.snmp" or
      String.starts_with?(subject, "logs.snmp.processed") or
      String.starts_with?(subject, "logs.internal.processed")
  end

  defp ignore_events_subject?(subject) do
    String.starts_with?(subject, "events.syslog") or
      String.starts_with?(subject, "events.snmp") or
      String.starts_with?(subject, "snmp.traps")
  end

  defp analytics_predictions_subject?(subject),
    do:
      subject == "signals.analytics.predictions" or
        String.starts_with?(subject, "signals.analytics.predictions.")

  # BMP routing events AND the generic analytics-signal catch-all (`signals.analytics.*`,
  # e.g. inventory/overlay verdicts) share the AnalyticsSignals processor + batcher.
  defp bmp_or_analytics_subject?(subject),
    do:
      subject == "bmp.events" or String.starts_with?(subject, "bmp.events.") or
        subject == "signals.analytics" or
        String.starts_with?(subject, "signals.analytics.")

  defp arancini_causal_subject?(subject),
    do: subject == "arancini.updates" or String.starts_with?(subject, "arancini.updates.")

  defp siem_causal_subject?(subject),
    do: subject == "siem.events" or String.starts_with?(subject, "siem.events.")

  defp pdns_ocsf_subject?(subject),
    do: subject == "pdns.ocsf" or String.starts_with?(subject, "pdns.ocsf.")

  defp falco_subject?(subject), do: subject == "falco" or String.starts_with?(subject, "falco.")

  defp trivy_subject?(subject),
    do: subject == "trivy.report" or String.starts_with?(subject, "trivy.report.")

  defp k8s_nodes_subject?(subject), do: subject == "inventory.k8s.nodes"

  defp k8s_inventory_subject?(subject),
    do:
      subject == "inventory.k8s.public_endpoints" or
        String.starts_with?(subject, "inventory.k8s.public_endpoints.")

  defp get_processor(:otel_metrics), do: ServiceRadar.EventWriter.Processors.OtelMetrics
  defp get_processor(:otel_traces), do: ServiceRadar.EventWriter.Processors.OtelTraces
  defp get_processor(:events), do: Events
  defp get_processor(:pdns_ocsf), do: PowerDNS
  defp get_processor(:falco), do: ServiceRadar.EventWriter.Processors.FalcoEvents
  defp get_processor(:trivy), do: ServiceRadar.EventWriter.Processors.TrivyReports
  defp get_processor(:k8s_inventory), do: ServiceRadar.EventWriter.Processors.K8sPublicEndpoints
  defp get_processor(:k8s_nodes), do: ServiceRadar.EventWriter.Processors.K8sNodes
  defp get_processor(:bmp_causal), do: AnalyticsSignals
  defp get_processor(:arancini_causal), do: AnalyticsSignals
  defp get_processor(:siem_causal), do: AnalyticsSignals
  defp get_processor(:analytics_predictions), do: AnalyticsSignals
  defp get_processor(:causal_signals), do: AnalyticsSignals
  defp get_processor(:logs), do: ServiceRadar.EventWriter.Processors.Logs
  defp get_processor(:metrics), do: Metrics
  defp get_processor(:telemetry), do: Telemetry
  defp get_processor(:edge_record), do: EdgeRecord
  defp get_processor(:flows_raw), do: Flows
  defp get_processor(:sflow_raw), do: Flows
  defp get_processor(:netflow_raw), do: Flows
  defp get_processor(_), do: ServiceRadar.EventWriter.Processors.Default

  # Map a configured stream name to its batcher atom WITHOUT minting atoms from runtime
  # config. Every real batcher (`:events`, `:metrics`, `:bmp_causal`,
  # `:analytics_predictions`, ...) already exists as a compile-time literal in
  # `batcher_rules/0` + `get_processor/1`, so `String.to_existing_atom/1` resolves them;
  # an unknown/custom stream name has no routing rule pointing at it, so it falls back to
  # the `:default` batcher (its messages route to the Default processor).
  defp stream_to_batcher_name(stream_name) do
    stream_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :default
  end
end
