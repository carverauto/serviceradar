defmodule ServiceRadarAgentGateway.GRPCTraceInterceptorTest do
  # async: false -- restarts the global OpenTelemetry SDK with a pid exporter and sets the
  # global text-map propagator.
  use ExUnit.Case, async: false

  alias ServiceRadar.Otel.Propagation
  alias ServiceRadarAgentGateway.GRPCTraceInterceptor

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @status_fields Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:status, @status_fields)

  # Synthetic W3C ids for the agent's CLIENT span.
  @agent_trace_id 0x0AF7651916CD43DD8448EB211C80319C
  @agent_span_id 0xB7AD6B7169203331
  @agent_traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  setup do
    old_injector = :opentelemetry.get_text_map_injector()
    old_extractor = :opentelemetry.get_text_map_extractor()
    old_env = Map.new([:traces_exporter, :processors], &{&1, Application.fetch_env(:opentelemetry, &1)})

    :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)
    Application.stop(:opentelemetry)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :processors, [{:otel_simple_processor, %{}}])
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    # A tracer cached before the restart names a processor that is gone (the SDK does not
    # invalidate that cache), and spans through it would never arrive.
    drop_cached_tracers()

    on_exit(fn ->
      Application.stop(:opentelemetry)

      Enum.each(old_env, fn
        {key, {:ok, value}} -> Application.put_env(:opentelemetry, key, value)
        {key, :error} -> Application.delete_env(:opentelemetry, key)
      end)

      {:ok, _} = Application.ensure_all_started(:opentelemetry)

      drop_cached_tracers()

      :opentelemetry.set_text_map_injector(old_injector)
      :opentelemetry.set_text_map_extractor(old_extractor)
    end)

    :ok
  end

  defp drop_cached_tracers do
    for {{:opentelemetry, _provider, :tracer, _name} = key, _tracer} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end
  end

  defp push_status_stream(headers) do
    %GRPC.Server.Stream{
      service_name: "monitoring.AgentGatewayService",
      method_name: "PushStatus",
      http_request_headers: headers
    }
  end

  test "runs the RPC in a SERVER span that is a child of the agent's CLIENT span" do
    stream = push_status_stream(%{"traceparent" => @agent_traceparent})

    next = fn request, stream ->
      # What the handler would hand on, for example to an edge-record publication.
      send(self(), {:handler_context, Propagation.trace_context_headers()})
      {:ok, stream, request}
    end

    assert {:ok, ^stream, :request} = GRPCTraceInterceptor.call(:request, stream, next, [])

    assert_receive {:span, span(name: "monitoring.AgentGatewayService/PushStatus", kind: :server) = server_span},
                   1_000

    assert span(server_span, :trace_id) == @agent_trace_id
    assert span(server_span, :parent_span_id) == @agent_span_id

    attributes = :otel_attributes.map(span(server_span, :attributes))
    assert attributes["rpc.system"] == "grpc"
    assert attributes["rpc.service"] == "monitoring.AgentGatewayService"
    assert attributes["rpc.method"] == "PushStatus"

    # The handler ran under the SERVER span, not under the agent's span.
    assert_receive {:handler_context, [{"traceparent", "00-0af7651916cd43dd8448eb211c80319c-" <> rest}]}
    refute String.starts_with?(rest, "b7ad6b7169203331")

    # Neither the remote parent nor the server span outlives the call.
    assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
  end

  test "an RPC without trace context gets a SERVER root span" do
    stream = push_status_stream(%{"content-type" => "application/grpc"})

    GRPCTraceInterceptor.call(:request, stream, fn request, stream -> {:ok, stream, request} end, [])

    assert_receive {:span, span(kind: :server, parent_span_id: :undefined)}, 1_000
  end

  test "a handler that raises ends the SERVER span with status ERROR and re-raises" do
    stream = push_status_stream(%{"traceparent" => @agent_traceparent})

    assert_raise GRPC.RPCError, fn ->
      GRPCTraceInterceptor.call(
        :request,
        stream,
        fn _request, _stream -> raise GRPC.RPCError, status: 7, message: "denied" end,
        []
      )
    end

    assert_receive {:span, span(kind: :server, status: span_status)}, 1_000
    assert status(span_status, :code) == :error
    assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
  end
end
