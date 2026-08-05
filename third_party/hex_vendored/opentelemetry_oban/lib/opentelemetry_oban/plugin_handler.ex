defmodule OpentelemetryOban.PluginHandler do
  alias OpenTelemetry.Tracer
  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def attach() do
    attach_plugin_start_handler()
    attach_plugin_stop_handler()
    attach_plugin_exception_handler()
  end

  defp attach_plugin_start_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_start",
      [:oban, :plugin, :start],
      &__MODULE__.handle_plugin_start/4,
      []
    )
  end

  defp attach_plugin_stop_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_stop",
      [:oban, :plugin, :stop],
      &__MODULE__.handle_plugin_stop/4,
      []
    )
  end

  defp attach_plugin_exception_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_exception",
      [:oban, :plugin, :exception],
      &__MODULE__.handle_plugin_exception/4,
      []
    )
  end

  def handle_plugin_start(_event, _measurements, %{plugin: plugin} = metadata, _config) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{plugin} process",
      metadata,
      %{attributes: %{"oban.plugin": plugin}}
    )
  end

  def handle_plugin_stop(_event, _measurements, metadata, _config) do
    Tracer.set_attributes(end_span_plugin_attrs(metadata))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_plugin_exception(
        _event,
        _measurements,
        %{kind: :error, reason: exception, stacktrace: stacktrace} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    # Record exception and mark the span as errored
    Span.record_exception(ctx, exception, stacktrace)
    Span.set_status(ctx, OpenTelemetry.status(:error, Exception.message(exception)))

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Plugins.Cron} = metadata) do
    %{"oban.plugins.cron.jobs_count": length(metadata[:jobs])}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Plugins.Gossip} = metadata) do
    %{"oban.plugins.gossip.gossip_count": metadata[:gossip_count]}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Plugins.Lifeline} = metadata) do
    %{
      "oban.plugins.lifeline.discarded_count": metadata[:discarded_count],
      "oban.plugins.lifeline.rescued_count": metadata[:rescued_count]
    }
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Plugins.Pruner} = metadata) do
    %{"oban.plugins.pruner.pruned_count": metadata[:pruned_count]}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Pro.Plugins.DynamicCron} = metadata) do
    %{"oban.pro.plugins.dynamic_cron.jobs_count": length(metadata[:jobs])}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Pro.Plugins.DynamicLifeline} = metadata) do
    %{
      "oban.pro.plugins.dynamic_lifeline.discarded_count": metadata[:discarded_count],
      "oban.pro.plugins.dynamic_lifeline.rescued_count": metadata[:rescued_count]
    }
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Pro.Plugins.DynamicPrioritizer} = metadata) do
    %{"oban.pro.plugins.dynamic_prioritizer.reprioritized_count": metadata[:reprioritized_count]}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Pro.Plugins.DynamicPruner} = metadata) do
    %{"oban.pro.plugins.dynamic_pruner.pruned_count": metadata[:pruned_count]}
  end

  defp end_span_plugin_attrs(%{plugin: Oban.Pro.Plugins.DynamicScaler} = metadata) do
    %{
      "oban.pro.plugins.dynamic_scaler.scaler.last_scaled_to": metadata[:scaler][:last_scaled_to],
      "oban.pro.plugins.dynamic_scaler.scaler.last_scaled_at":
        DateTime.to_iso8601(metadata[:scaler][:last_scaled_at])
    }
  end

  defp end_span_plugin_attrs(_) do
    %{}
  end
end
