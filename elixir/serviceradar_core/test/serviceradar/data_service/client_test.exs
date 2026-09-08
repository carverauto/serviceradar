defmodule ServiceRadar.DataService.ClientTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.DataService.Client

  @moduletag :requires_app

  test "get_channel returns not_started when the supervised client is unavailable" do
    refute Process.whereis(Client)

    assert {:error, :not_started} = Client.get_channel(timeout: 10)
    refute Client.connected?()
  end

  test "connected? keeps an established virtual channel without probing the adapter process" do
    start_supervised!(
      {Client,
       host: "127.0.0.1",
       port: 1,
       sec_mode: "plaintext",
       connect_timeout_ms: 10,
       reconnect_base_ms: 60_000,
       reconnect_max_ms: 60_000}
    )

    :sys.replace_state(
      Client,
      fn state -> %{state | channel: %GRPC.Channel{}, connect_task: nil} end,
      15_000
    )

    assert Client.connected?()
    assert {:ok, %GRPC.Channel{}} = Client.get_channel(timeout: 10)
  end
end
