defmodule ServiceRadar.Otel.GRPCClientInterceptor do
  @moduledoc """
  gRPC client interceptor that runs each call in an OpenTelemetry CLIENT span
  and propagates that span's W3C trace context in the request metadata.

  Without it, a call from an Elixir service to a Go service (datasvc) carries no
  `traceparent`, so the server's `otelgrpc` span is stored as an unparented
  root. With it, the server span is a child of this CLIENT span. The span is
  created whether or not a span is already active: most datasvc calls run
  outside any span, and a CLIENT root with a parented server child is still a
  connected two-span trace.

  Attach it to a channel as `interceptors: [{#{inspect(__MODULE__)}, []}]`
  (or pass the module to `GRPC.Stub.connect/2`'s `:interceptors`).
  """

  @behaviour GRPC.Client.Interceptor

  alias GRPC.Client.Stream
  alias ServiceRadar.Otel
  alias ServiceRadar.Otel.Propagation

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Stream{} = stream, request, next, _opts) do
    Otel.span(span_name(stream), %{kind: :client, attributes: attributes(stream)}, fn ->
      stream
      |> Stream.put_headers(Map.new(Propagation.inject_headers([])))
      |> next.(request)
      |> tap(&record_failure/1)
    end)
  end

  defp span_name(%Stream{service_name: service, method_name: method})
       when is_binary(service) and is_binary(method),
       do: service <> "/" <> method

  defp span_name(%Stream{path: path}) when is_binary(path), do: String.trim_leading(path, "/")
  defp span_name(_stream), do: "grpc.client"

  defp attributes(%Stream{} = stream) do
    %{"rpc.system" => "grpc"}
    |> put_present("rpc.service", stream.service_name)
    |> put_present("rpc.method", stream.method_name)
    |> put_present("server.address", channel_host(stream.channel))
  end

  defp channel_host(%GRPC.Channel{host: host}) when is_binary(host), do: host
  defp channel_host(_channel), do: nil

  defp put_present(attributes, key, value) when is_binary(value) and value != "",
    do: Map.put(attributes, key, value)

  defp put_present(attributes, _key, _value), do: attributes

  defp record_failure({:error, %GRPC.RPCError{status: status, message: message}}),
    do: Otel.set_error("grpc status #{status}: #{message}")

  defp record_failure({:error, reason}), do: Otel.set_error(reason)
  defp record_failure(_result), do: :ok
end
