defmodule ServiceRadar.Otel.GRPCClientInterceptorTest do
  # async: false — OtelSpanCapture restarts the global OpenTelemetry SDK.
  use ExUnit.Case, async: false

  alias ServiceRadar.Otel
  alias ServiceRadar.Otel.GRPCClientInterceptor
  alias ServiceRadar.TestSupport.OtelSpanCapture

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @status_fields Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:status, @status_fields)

  setup do
    OtelSpanCapture.start!()
  end

  defp kv_get_stream do
    %GRPC.Client.Stream{
      service_name: "proto.KVService",
      method_name: "Get",
      channel: %GRPC.Channel{host: "datasvc.example.com"},
      headers: %{}
    }
  end

  # The metadata the transport would send, captured where the adapter takes over.
  defp capturing_next(reply) do
    test = self()

    fn stream, _request ->
      send(test, {:sent_headers, stream.headers})
      reply
    end
  end

  test "sends the CLIENT span's context as the W3C traceparent of the call, under the caller's span" do
    reply =
      Otel.span("caller", %{}, fn ->
        GRPCClientInterceptor.call(kv_get_stream(), :request, capturing_next({:ok, :reply}), [])
      end)

    assert reply == {:ok, :reply}
    assert_receive {:sent_headers, headers}

    assert_receive {:span, span(name: "proto.KVService/Get", kind: :client) = client_span},
                   1_000

    assert_receive {:span, span(name: "caller") = caller_span}, 1_000

    # W3C Trace Context: version 00, 32-hex trace id, 16-hex parent id, sampled flag.
    assert headers["traceparent"] ==
             "00-#{hex(span(client_span, :trace_id), 32)}-#{hex(span(client_span, :span_id), 16)}-01"

    assert span(client_span, :trace_id) == span(caller_span, :trace_id)
    assert span(client_span, :parent_span_id) == span(caller_span, :span_id)

    attributes = :otel_attributes.map(span(client_span, :attributes))
    assert attributes["rpc.system"] == "grpc"
    assert attributes["rpc.service"] == "proto.KVService"
    assert attributes["rpc.method"] == "Get"
    assert attributes["server.address"] == "datasvc.example.com"
  end

  test "a call with no span active still sends context, from a CLIENT root span" do
    GRPCClientInterceptor.call(kv_get_stream(), :request, capturing_next({:ok, :reply}), [])

    assert_receive {:sent_headers, %{"traceparent" => "00-" <> _}}
    assert_receive {:span, span(kind: :client, parent_span_id: :undefined)}, 1_000
  end

  test "a failed call ends its CLIENT span with status ERROR" do
    failure = {:error, %GRPC.RPCError{status: 14, message: "unavailable"}}

    assert GRPCClientInterceptor.call(kv_get_stream(), :request, capturing_next(failure), []) ==
             failure

    assert_receive {:span, span(kind: :client, status: span_status)}, 1_000
    assert status(span_status, :code) == :error
  end

  defp hex(id, width) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
  end
end
