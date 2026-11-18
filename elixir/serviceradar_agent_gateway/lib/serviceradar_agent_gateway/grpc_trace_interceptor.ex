defmodule ServiceRadarAgentGateway.GRPCTraceInterceptor do
  @moduledoc """
  Runs each gateway RPC in an OpenTelemetry SERVER span parented on the
  caller's W3C trace context.

  The agent's `otelgrpc` client sends `traceparent` (and `tracestate`) in the
  request metadata. This interceptor extracts that context and starts the SERVER
  span under it, so the agent's CLIENT span gains its server half instead of
  standing alone as a single-span trace. Unary RPCs get one span per call, and
  streaming RPCs one span for the stream's lifetime.

  The span is the active context while the handler runs, so work the handler
  hands on (an edge-record publication, see `ServiceRadarAgentGateway.EdgeRecordIngestServer`)
  can carry it further.
  """

  @behaviour GRPC.Server.Interceptor

  alias ServiceRadar.Otel

  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def init(opts), do: opts

  @impl true
  def call(request, stream, next, _opts) do
    parent_ctx = :otel_ctx.get_current()
    attach_remote_parent(stream)

    try do
      Otel.span(span_name(stream), %{kind: :server, attributes: attributes(stream)}, fn ->
        request
        |> next.(stream)
        |> tap(&record_failure/1)
      end)
    after
      :otel_ctx.attach(parent_ctx)
    end
  end

  # An absent or malformed traceparent leaves the current context untouched, and the SERVER
  # span is then a root.
  defp attach_remote_parent(%{http_request_headers: headers}) when is_map(headers) and map_size(headers) > 0 do
    :otel_propagator_text_map.extract(Map.to_list(headers))
  end

  defp attach_remote_parent(_stream), do: :ok

  defp span_name(%{service_name: service, method_name: method}) when is_binary(service) and is_binary(method),
    do: service <> "/" <> method

  defp span_name(_stream), do: "grpc.server"

  defp attributes(stream) do
    %{"rpc.system" => "grpc"}
    |> put_present("rpc.service", Map.get(stream, :service_name))
    |> put_present("rpc.method", Map.get(stream, :method_name))
  end

  defp put_present(attributes, key, value) when is_binary(value) and value != "", do: Map.put(attributes, key, value)

  defp put_present(attributes, _key, _value), do: attributes

  defp record_failure({:error, %GRPC.RPCError{status: status, message: message}}) do
    Tracer.set_attribute("rpc.grpc.status_code", status)
    Otel.set_error("grpc status #{status}: #{message}")
  end

  defp record_failure({:error, reason}), do: Otel.set_error(reason)
  defp record_failure(_result), do: :ok
end
