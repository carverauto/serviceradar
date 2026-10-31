defmodule ServiceRadarAgentGateway.GRPCExceptionLogFilter do
  @moduledoc """
  Decides which gRPC handler errors the server adapter logs as crash reports.

  Handlers return a gRPC error status by raising `GRPC.RPCError`, for example `:not_found` for an
  unknown relay session or `:aborted` while core is unavailable. The gRPC adapter logs every such
  raise as an error-level crash report that carries the whole request, including the client
  certificate, so an expected status looked like an unhandled crash.

  A status a handler raises on purpose is logged here as one warning line naming the path, the
  status and the message, and the crash report is skipped. `unknown`, `internal` and `data_loss`
  statuses, and any exception that is not a `GRPC.RPCError`, keep the full crash report.
  """

  alias GRPC.Server.Adapters.ReportException

  require Logger

  @crash_statuses [GRPC.Status.unknown(), GRPC.Status.internal(), GRPC.Status.data_loss()]
  @max_log_value_bytes 256

  @doc "Returns whether the adapter should log `exception` as a crash report."
  @spec report?(Exception.t()) :: boolean()
  def report?(%ReportException{reason: %GRPC.RPCError{status: status} = error} = exception)
      when is_integer(status) and status not in @crash_statuses do
    Logger.warning(
      "gRPC request returned path=#{request_path(exception)} " <>
        "status=#{GRPC.Status.code_name(status)} message=#{safe_log_value(error.message)}"
    )

    false
  end

  def report?(_exception), do: true

  defp request_path(%ReportException{adapter_extra: [req: %{path: path}]}) when is_binary(path), do: safe_log_value(path)

  defp request_path(_exception), do: "unknown"

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]+/, " ")
    |> String.slice(0, @max_log_value_bytes)
  end

  defp safe_log_value(_value), do: ""
end
