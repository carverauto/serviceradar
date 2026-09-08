defmodule ServiceRadarAgentGateway.SafeGrpcLogger do
  @moduledoc """
  Body-redacting gRPC server logger.

  The upstream gRPC logger is intentionally generic. This interceptor keeps the
  agent-gateway log contract narrow: method, duration, status, and peer identity
  only. Request and response structs are never inspected or logged.
  """

  @behaviour GRPC.Server.Interceptor

  require Logger

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

      actor = peer_actor(stream)
      start = System.monotonic_time()
      result = next.(req, stream)
      duration_us = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)
      method = rpc_method(stream)
      status = result_status(result)
      actor_for_log = actor || "unknown"

      Logger.log(
        level,
        "gRPC request completed server=#{inspect(stream.server)} method=#{method} status=#{status} duration_us=#{duration_us} actor=#{actor_for_log}"
      )

      result
    end
  end

  defp rpc_method(%{rpc: {method, _}}) when is_atom(method), do: Atom.to_string(method)
  defp rpc_method(%{method_name: method}) when is_binary(method) and method != "", do: method
  defp rpc_method(_stream), do: "unknown"

  defp result_status({:ok, _stream}), do: :ok
  defp result_status({:ok, _stream, _reply}), do: :ok
  defp result_status({:error, %GRPC.RPCError{status: status}}), do: status
  defp result_status({:error, _reason}), do: :error
  defp result_status(_result), do: :unknown

  defp peer_actor(stream) do
    with {:ok, cert_der} <- peer_cert(stream),
         {:ok, %{component_id: component_id}} <-
           ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_from_cert(cert_der) do
      component_id
    else
      _ -> nil
    end
  end

  defp peer_cert(%{adapter: adapter, payload: payload}) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :get_cert, 1) do
      case adapter.get_cert(payload) do
        cert_der when is_binary(cert_der) -> {:ok, cert_der}
        _ -> {:error, :no_certificate}
      end
    else
      {:error, :cert_extraction_unsupported}
    end
  rescue
    _ -> {:error, :cert_extraction_failed}
  catch
    _, _ -> {:error, :cert_extraction_failed}
  end

  defp peer_cert(_stream), do: {:error, :cert_extraction_unsupported}
end
