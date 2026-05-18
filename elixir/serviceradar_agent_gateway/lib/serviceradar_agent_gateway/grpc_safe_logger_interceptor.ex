defmodule ServiceRadarAgentGateway.GRPCSafeLoggerInterceptor do
  @moduledoc """
  Logs gRPC server calls without serializing request or response bodies.
  """

  @behaviour GRPC.Server.Interceptor

  require Logger

  @unknown "unknown"
  @max_log_value_bytes 128

  @impl true
  def init(opts) do
    Keyword.validate!(opts, level: :info)
  end

  @impl true
  def call(req, stream, next, opts) do
    level = Keyword.fetch!(opts, :level)

    if Logger.compare_levels(level, Logger.level()) == :lt do
      next.(req, stream)
    else
      Logger.metadata(request_id: Logger.metadata()[:request_id] || stream.request_id)

      started_at = System.monotonic_time()
      result = next.(req, stream)
      duration_us = System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)

      Logger.log(level, fn ->
        "Handled gRPC request method=#{grpc_method(stream)} status=#{result_status(result)} duration_us=#{duration_us} actor=#{actor_id(stream)}"
      end)

      result
    end
  end

  defp grpc_method(%{service_name: service_name, method_name: method_name})
       when is_binary(service_name) and is_binary(method_name) do
    safe_log_value(service_name <> "/" <> method_name)
  end

  defp grpc_method(%{server: server, rpc: {method_name, _}}) do
    safe_log_value("#{inspect(server)}.#{method_name}")
  end

  defp grpc_method(_stream), do: @unknown

  defp result_status({:ok, _stream, _response}), do: "ok"
  defp result_status({:ok, _stream}), do: "ok"
  defp result_status({:error, %GRPC.RPCError{status: status}}), do: safe_log_value("error:#{status}")
  defp result_status({:error, _reason}), do: "error"
  defp result_status(_result), do: @unknown

  defp actor_id(%{local: local}) do
    local
    |> local_actor_id()
    |> Kernel.||(Logger.metadata()[:actor_id])
    |> safe_log_value()
  end

  defp actor_id(_stream), do: safe_log_value(Logger.metadata()[:actor_id])

  defp local_actor_id(local) when is_map(local) do
    local[:actor_id] || local["actor_id"] || local[:actor] || local["actor"]
  end

  defp local_actor_id(_local), do: nil

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]+/, " ")
    |> String.slice(0, @max_log_value_bytes)
    |> case do
      "" -> @unknown
      value -> value
    end
  end

  defp safe_log_value(value) when is_atom(value), do: value |> Atom.to_string() |> safe_log_value()
  defp safe_log_value(value) when is_integer(value), do: value |> Integer.to_string() |> safe_log_value()
  defp safe_log_value(_value), do: @unknown
end
