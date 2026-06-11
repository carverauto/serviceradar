defmodule ServiceRadar.Otel.PropagationTest do
  # async: false — sets the globally registered text-map propagator.
  use ExUnit.Case, async: false

  alias ServiceRadar.Otel.Propagation

  @trace_id 0x0AF7651916CD43DD8448EB211C80319C
  @span_id 0xB7AD6B7169203331
  @hex_trace_id "0af7651916cd43dd8448eb211c80319c"
  @hex_span_id "b7ad6b7169203331"
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  setup do
    old_injector = :opentelemetry.get_text_map_injector()
    old_extractor = :opentelemetry.get_text_map_extractor()

    :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)

    on_exit(fn ->
      :opentelemetry.set_text_map_injector(old_injector)
      :opentelemetry.set_text_map_extractor(old_extractor)
    end)

    :ok
  end

  defp set_remote_span do
    span_ctx = :otel_tracer.from_remote_span(@trace_id, @span_id, 1)
    OpenTelemetry.Tracer.set_current_span(span_ctx)
    span_ctx
  end

  describe "inject_headers/1" do
    test "is a no-op without an active span context" do
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
      assert Propagation.inject_headers([]) == []
      assert Propagation.inject_headers([{"foo", "bar"}]) == [{"foo", "bar"}]
    end

    test "adds a traceparent header matching the active span context" do
      set_remote_span()

      headers = Propagation.inject_headers([])

      assert [{"traceparent", @traceparent}] = headers
    end

    test "preserves unrelated existing headers" do
      set_remote_span()

      headers = Propagation.inject_headers([{"Nats-Msg-Id", "abc"}])

      assert {"Nats-Msg-Id", "abc"} in headers
      assert {"traceparent", @traceparent} in headers
    end

    test "replaces an existing traceparent instead of duplicating it" do
      set_remote_span()

      headers =
        Propagation.inject_headers([
          {"traceparent", "00-11111111111111111111111111111111-2222222222222222-01"}
        ])

      assert Enum.count(headers, fn {k, _} -> String.downcase(k) == "traceparent" end) == 1
      assert {"traceparent", @traceparent} in headers
    end
  end

  describe "extract_context/1" do
    test "attaches the remote parent from a header list" do
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined

      assert :ok = Propagation.extract_context([{"traceparent", @traceparent}])

      span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      assert span_ctx != :undefined
      assert :otel_span.trace_id(span_ctx) == @trace_id
      assert :otel_span.span_id(span_ctx) == @span_id
      assert :otel_span.hex_trace_id(span_ctx) == @hex_trace_id
      assert :otel_span.hex_span_id(span_ctx) == @hex_span_id
    end

    test "accepts a header map carrier" do
      assert :ok = Propagation.extract_context(%{"traceparent" => @traceparent})

      span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      assert :otel_span.trace_id(span_ctx) == @trace_id
      assert :otel_span.span_id(span_ctx) == @span_id
    end

    test "leaves the context untouched for malformed traceparent" do
      assert :ok = Propagation.extract_context([{"traceparent", "garbage"}])
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
    end

    test "leaves the context untouched for empty or unusable carriers" do
      assert :ok = Propagation.extract_context([])
      assert :ok = Propagation.extract_context(%{})
      assert :ok = Propagation.extract_context(nil)
      assert :ok = Propagation.extract_context([{:weird, 42}, "not-a-tuple"])
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
    end
  end

  describe "extract_link/1" do
    test "builds a link from a header list without touching the current context" do
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined

      link = Propagation.extract_link([{"traceparent", @traceparent}])

      assert %{trace_id: @trace_id, span_id: @span_id} = link
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
    end

    test "builds a link from a header map carrier" do
      assert %{trace_id: @trace_id, span_id: @span_id} =
               Propagation.extract_link(%{"traceparent" => @traceparent})
    end

    test "returns nil for malformed traceparent" do
      assert Propagation.extract_link([{"traceparent", "garbage"}]) == nil
    end

    test "returns nil for empty or unusable carriers" do
      assert Propagation.extract_link([]) == nil
      assert Propagation.extract_link(%{}) == nil
      assert Propagation.extract_link(nil) == nil
      assert Propagation.extract_link([{"Nats-Msg-Id", "abc"}]) == nil
      assert Propagation.extract_link([{:weird, 42}, "not-a-tuple"]) == nil
    end
  end

  describe "round trip" do
    test "publisher inject -> consumer extract preserves trace and span ids" do
      set_remote_span()
      headers = Propagation.inject_headers([])

      task =
        Task.async(fn ->
          assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
          :ok = Propagation.extract_context(headers)
          span_ctx = OpenTelemetry.Tracer.current_span_ctx()
          {:otel_span.trace_id(span_ctx), :otel_span.span_id(span_ctx)}
        end)

      assert Task.await(task) == {@trace_id, @span_id}
    end
  end
end
