defmodule ServiceRadarAgentGateway.GRPCExceptionLogFilterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias GRPC.Server.Adapters.ReportException
  alias ServiceRadarAgentGateway.GRPCExceptionLogFilter

  @client_cert "-----CLIENT CERTIFICATE DER-----"

  test "an expected status is one warning line instead of a crash report" do
    exception =
      report(%GRPC.RPCError{
        status: GRPC.Status.aborted(),
        message: "failed to heartbeat upstream relay session: :core_unavailable"
      })

    log =
      capture_log([level: :warning], fn ->
        refute GRPCExceptionLogFilter.report?(exception)
      end)

    assert log =~
             "gRPC request returned path=/camera.CameraMediaService/Heartbeat status=Aborted " <>
               "message=failed to heartbeat upstream relay session: :core_unavailable"

    refute log =~ @client_cert
  end

  test "internal failures and non-RPC exceptions keep the crash report" do
    for reason <- [
          %GRPC.RPCError{status: GRPC.Status.unknown(), message: "Internal Server Error"},
          %GRPC.RPCError{status: GRPC.Status.internal(), message: "encode failed"},
          %RuntimeError{message: "boom"}
        ] do
      assert GRPCExceptionLogFilter.report?(report(reason))
    end
  end

  defp report(reason) do
    ReportException.new(
      [req: %{path: "/camera.CameraMediaService/Heartbeat", cert: @client_cert}],
      reason
    )
  end
end
