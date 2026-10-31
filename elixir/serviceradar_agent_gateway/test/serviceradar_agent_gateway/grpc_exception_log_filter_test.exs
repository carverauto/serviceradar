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

  test "another expected status is sanitized the same way" do
    noisy = "missing\r\nsession " <> String.duplicate("y", 300)

    exception =
      report(
        %GRPC.RPCError{status: GRPC.Status.not_found(), message: noisy},
        path: "/camera.CameraMediaService/Heartbeat\n" <> String.duplicate("p", 300)
      )

    log =
      capture_log([level: :warning], fn ->
        refute GRPCExceptionLogFilter.report?(exception)
      end)

    sanitized_message = "missing session " <> String.duplicate("y", 240)
    sanitized_path = "/camera.CameraMediaService/Heartbeat " <> String.duplicate("p", 219)

    assert log =~
             "gRPC request returned path=#{sanitized_path} status=NotFound message=#{sanitized_message}"

    assert byte_size(sanitized_message) == 256
    assert byte_size(sanitized_path) == 256
    refute log =~ @client_cert
    refute log =~ "Heartbeat\n"
    refute log =~ "\r"
  end

  test "internal failures and non-RPC exceptions keep the crash report" do
    for reason <- [
          %GRPC.RPCError{status: GRPC.Status.unknown(), message: "Internal Server Error"},
          %GRPC.RPCError{status: GRPC.Status.internal(), message: "encode failed"},
          %GRPC.RPCError{status: GRPC.Status.data_loss(), message: "lost"},
          %RuntimeError{message: "boom"}
        ] do
      assert GRPCExceptionLogFilter.report?(report(reason))
    end
  end

  defp report(reason, opts \\ []) do
    path = Keyword.get(opts, :path, "/camera.CameraMediaService/Heartbeat")

    ReportException.new([req: %{path: path, cert: @client_cert}], reason)
  end
end
