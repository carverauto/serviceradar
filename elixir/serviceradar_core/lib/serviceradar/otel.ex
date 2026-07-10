defmodule ServiceRadar.Otel do
  @moduledoc """
  Minimal OpenTelemetry helpers for manual spans.

  The auto-instrumentation libraries (Phoenix, Ecto, Oban) record exception
  status on their own spans, but the bare `OpenTelemetry.Tracer.with_span/3`
  macro does NOT: an exception escaping the block ends the span with status
  UNSET, so error-rate rollups never see the failure. Manual spans in
  ServiceRadar should go through `span/3`, which records the exception event
  and sets OTLP status ERROR (status_code=2) before re-raising.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Runs `fun` inside a span named `name`, recording exception details and
  setting span status to `:error` when the function raises, throws, or exits.

  The original exception/exit/throw is re-raised with its stacktrace intact.

  `start_opts` is passed to `OpenTelemetry.Tracer.with_span/3` (e.g.
  `%{kind: :producer, attributes: %{...}}`).
  """
  @spec span(:opentelemetry.span_name(), map() | keyword(), (-> result)) :: result
        when result: var
  def span(name, start_opts \\ %{}, fun) when is_function(fun, 0) do
    Tracer.with_span name, Map.new(start_opts) do
      run_span(fun)
    end
  end

  @doc false
  @spec span_with_tracer(
          :opentelemetry.tracer(),
          :opentelemetry.span_name(),
          map() | keyword(),
          (-> result)
        ) :: result
        when result: var
  def span_with_tracer(tracer, name, start_opts, fun) when is_function(fun, 0) do
    :otel_tracer.with_span(tracer, name, Map.new(start_opts), fn _span_ctx ->
      run_span(fun)
    end)
  end

  @doc false
  @spec provider_identity() :: pid() | nil
  def provider_identity, do: Process.whereis(:otel_tracer_provider_global)

  @doc false
  @spec tracer_for_application(module(), pid() | nil) :: :opentelemetry.tracer()
  def tracer_for_application(application, provider \\ provider_identity()) do
    case :opentelemetry.get_application(application) do
      {name, version, schema_url} when is_pid(provider) ->
        :otel_tracer_provider.get_tracer(provider, name, version, schema_url)

      {name, version, schema_url} ->
        :opentelemetry.get_tracer(name, version, schema_url)

      _unknown_application when is_pid(provider) ->
        :otel_tracer_provider.get_tracer(provider, application, :undefined, :undefined)

      _unknown_application ->
        :opentelemetry.get_tracer(application, :undefined, :undefined)
    end
  end

  @doc """
  Marks the current span as failed without raising.

  Useful at call sites where failures are `{:error, reason}` values rather
  than exceptions.
  """
  @spec set_error(term()) :: :ok
  def set_error(reason) do
    Tracer.set_status(:error, format_reason(reason))
    :ok
  end

  defp run_span(fun) do
    fun.()
  rescue
    exception ->
      Tracer.record_exception(exception, __STACKTRACE__)
      Tracer.set_status(:error, Exception.message(exception))
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      Tracer.set_status(:error, Exception.format_banner(kind, reason))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
