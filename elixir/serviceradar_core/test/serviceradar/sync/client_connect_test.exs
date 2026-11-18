defmodule ServiceRadar.Sync.ClientConnectTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Sync.Client

  # The :grpc application owns GRPC.Client.Supervisor, which GRPC.Stub.connect/2 starts each
  # connection under. The unit lane does not boot the core application tree.
  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:grpc)
    :ok
  end

  test "connect/1 with ssl returns an error for an unreachable endpoint instead of raising" do
    port = unused_port()

    log =
      capture_log(fn ->
        assert {:error, _reason} = Client.connect(host: "127.0.0.1", port: port, ssl: true)
      end)

    assert log =~ "Failed to connect to sync service at 127.0.0.1:#{port}"
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
