defmodule ServiceRadar.Telemetry.OtelGrpcboxChannelTest do
  use ExUnit.Case, async: false

  @moduletag :db_free

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:grpcbox)
    :ok
  end

  test "a recovered channel outlives the short-lived export caller" do
    channel = {:serviceradar_otel_channel_test, System.unique_integer([:positive])}
    endpoints = [{:http, ~c"127.0.0.1", 9, []}]
    parent = self()

    on_exit(fn ->
      try do
        :grpcbox_channel.stop(channel, :shutdown)
      catch
        _, _ -> :ok
      end
    end)

    {caller, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:channel_started, :serviceradar_otel_grpcbox_channel.start(channel, endpoints, nil)}
        )
      end)

    assert_receive {:channel_started, {:ok, channel_pid}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
    assert Process.alive?(channel_pid)
    assert :grpcbox_channel.is_ready(channel)
  end
end
