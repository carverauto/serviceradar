defmodule OpentelemetryOban.JobHandler do
  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes, as: MessagingAttributes

  @tracer_id __MODULE__

  def attach() do
    attach_job_start_handler()
    attach_job_stop_handler()
    attach_job_exception_handler()
  end

  defp attach_job_start_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_start",
      [:oban, :job, :start],
      &__MODULE__.handle_job_start/4,
      []
    )
  end

  defp attach_job_stop_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_stop",
      [:oban, :job, :stop],
      &__MODULE__.handle_job_stop/4,
      []
    )
  end

  defp attach_job_exception_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_exception",
      [:oban, :job, :exception],
      &__MODULE__.handle_job_exception/4,
      []
    )
  end

  def handle_job_start(_event, _measurements, metadata, _config) do
    %{
      job: %{
        id: id,
        queue: queue,
        worker: worker,
        priority: priority,
        inserted_at: inserted_at,
        scheduled_at: scheduled_at,
        attempt: attempt,
        max_attempts: max_attempts,
        meta: job_meta
      }
    } = metadata

    :otel_propagator_text_map.extract(Map.to_list(job_meta))
    parent = OpenTelemetry.Tracer.current_span_ctx()
    links = if parent == :undefined, do: [], else: [OpenTelemetry.link(parent)]
    OpenTelemetry.Tracer.set_current_span(:undefined)

    attributes = %{
      MessagingAttributes.messaging_system() => :oban,
      MessagingAttributes.messaging_destination_name() => queue,
      MessagingAttributes.messaging_operation_type() => :process,
      :"oban.job.job_id" => id,
      :"oban.job.worker" => worker,
      :"oban.job.priority" => priority,
      :"oban.job.attempt" => attempt,
      :"oban.job.max_attempts" => max_attempts,
      :"oban.job.inserted_at" => DateTime.to_iso8601(inserted_at),
      :"oban.job.scheduled_at" => DateTime.to_iso8601(scheduled_at)
    }

    span_name = "#{worker} process"

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, span_name, metadata, %{
      kind: :consumer,
      links: links,
      attributes: attributes
    })
  end

  def handle_job_stop(_event, _measurements, metadata, _config) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_job_exception(
        _event,
        _measurements,
        %{stacktrace: stacktrace, error: error} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    # Record exception and mark the span as errored
    Span.record_exception(ctx, error, stacktrace)
    Span.set_status(ctx, OpenTelemetry.status(:error, ""))

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end
end
