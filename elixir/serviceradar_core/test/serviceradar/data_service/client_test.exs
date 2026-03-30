defmodule ServiceRadar.DataService.ClientTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.DataService.Client

  test "get_channel returns not_started when the supervised client is unavailable" do
    refute Process.whereis(Client)

    assert {:error, :not_started} = Client.get_channel(timeout: 10)
  end
end
