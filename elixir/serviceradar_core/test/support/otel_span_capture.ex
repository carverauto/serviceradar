defmodule ServiceRadar.TestSupport.OtelSpanCapture do
  @moduledoc """
  Captures finished OpenTelemetry spans in a test process.

  `start!/1` sets the W3C trace-context propagator and restarts the SDK with a
  synchronous pid exporter, so every span that ends is delivered to the owner as
  `{:span, span_record}` (the `otel_span.hrl` record). It registers an `on_exit`
  that restores the previous SDK configuration and propagators. The SDK and the
  propagators are global, so a test module using this must be `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @otel_env_keys [:traces_exporter, :processors, :sampler]

  @doc "Starts capturing spans for `owner` until the calling test exits."
  @spec start!(pid()) :: :ok
  def start!(owner \\ self()) do
    old_injector = :opentelemetry.get_text_map_injector()
    old_extractor = :opentelemetry.get_text_map_extractor()
    old_otel_env = Map.new(@otel_env_keys, &{&1, Application.fetch_env(:opentelemetry, &1)})

    :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)
    restart!(owner)

    # `OpenTelemetry.Tracer` macros resolve a module's tracer through a persistent_term cache
    # that an SDK restart does not invalidate; a tracer cached before this restart names a
    # processor that is gone, and its spans would never reach the owner.
    drop_cached_tracers()

    on_exit(fn ->
      Application.stop(:opentelemetry)
      Enum.each(old_otel_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _} = Application.ensure_all_started(:opentelemetry)

      # A tracer cached while the pid-exporter SDK ran still names its simple processor,
      # which no longer exists; a later span in another test would exit on it.
      drop_cached_tracers()

      :opentelemetry.set_text_map_injector(old_injector)
      :opentelemetry.set_text_map_extractor(old_extractor)
    end)

    :ok
  end

  @doc """
  Restarts the SDK with the pid exporter for `owner` and the given sampler.

  Unlike `start!/1` it leaves the tracer cache alone, so a test can check that code under
  test does not use a tracer cached before the restart.
  """
  @spec restart!(pid(), atom()) :: :ok
  def restart!(owner, sampler \\ :always_on) do
    Application.stop(:opentelemetry)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :processors, [{:otel_simple_processor, %{}}])
    Application.put_env(:opentelemetry, :sampler, sampler)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :otel_simple_processor.set_exporter(:otel_exporter_pid, owner)
    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:opentelemetry, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:opentelemetry, key)

  defp drop_cached_tracers do
    for {{:opentelemetry, _provider, :tracer, _name} = key, _tracer} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end
  end
end
