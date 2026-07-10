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

  @global_provider_name :otel_tracer_provider_global
  @noop_tracer {:otel_tracer_noop, []}

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
  def provider_identity, do: Process.whereis(@global_provider_name)

  @doc false
  @spec tracer_for_application(module(), pid() | nil) :: :opentelemetry.tracer()
  def tracer_for_application(application, provider \\ provider_identity()) do
    application
    |> tracer_snapshot(provider)
    |> elem(1)
  end

  @doc false
  @spec tracer_snapshot(module(), pid() | nil) :: {pid() | nil, :opentelemetry.tracer()}
  def tracer_snapshot(application, provider \\ provider_identity()) do
    application
    |> application_scope()
    |> fetch_tracer_snapshot(provider, true)
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

  defp application_scope(application) do
    case :opentelemetry.get_application(application) do
      {name, version, schema_url} -> {name, version, schema_url}
      _unknown_application -> {application, :undefined, :undefined}
    end
  end

  defp fetch_tracer_snapshot(scope, provider, retry?) when is_pid(provider) do
    case safe_provider_tracer(provider, scope) do
      {:ok, @noop_tracer} ->
        retry_if_provider_changed(scope, provider, retry?, {provider, @noop_tracer})

      {:ok, tracer} ->
        {provider, tracer}

      :unavailable ->
        # Cache the noop under nil so a still-registered provider is retried on
        # the next call rather than suppressing tracing for that worker.
        retry_if_provider_changed(scope, provider, retry?, {nil, @noop_tracer})
    end
  end

  defp fetch_tracer_snapshot(scope, _provider, true) do
    case provider_identity() do
      provider when is_pid(provider) -> fetch_tracer_snapshot(scope, provider, false)
      nil -> {nil, @noop_tracer}
    end
  end

  defp fetch_tracer_snapshot(_scope, _provider, false), do: {nil, @noop_tracer}

  defp retry_if_provider_changed(scope, attempted_provider, true, fallback) do
    case provider_identity() do
      provider when is_pid(provider) and provider != attempted_provider ->
        fetch_tracer_snapshot(scope, provider, false)

      _same_or_missing_provider ->
        fallback
    end
  end

  defp retry_if_provider_changed(_scope, _attempted_provider, false, fallback), do: fallback

  defp safe_provider_tracer(provider, {name, version, schema_url}) do
    {:ok, :otel_tracer_provider.get_tracer(provider, name, version, schema_url)}
  catch
    :exit, _provider_lifecycle_reason -> :unavailable
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
