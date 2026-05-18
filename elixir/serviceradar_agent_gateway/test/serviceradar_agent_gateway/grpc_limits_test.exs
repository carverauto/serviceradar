defmodule ServiceRadarAgentGateway.GrpcLimitsTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.Application, as: GatewayApplication

  setup do
    env_names = [
      "GATEWAY_GRPC_IDLE_TIMEOUT_MS",
      "GATEWAY_GRPC_INACTIVITY_TIMEOUT_MS",
      "GATEWAY_GRPC_MAX_CONCURRENT_STREAMS",
      "GATEWAY_GRPC_MAX_CONNECTIONS",
      "GATEWAY_GRPC_MAX_FRAME_SIZE_BYTES"
    ]

    original = Map.new(env_names, &{&1, System.get_env(&1)})
    Enum.each(env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "edge gRPC adapter opts set bounded stream and frame defaults" do
    opts = GatewayApplication.edge_grpc_adapter_opts(:credential)

    assert opts[:cred] == :credential
    assert opts[:idle_timeout] == 30_000
    assert opts[:inactivity_timeout] == 10_000
    assert opts[:max_concurrent_streams] == 100
    assert opts[:max_connections] == 1_000
    assert opts[:max_frame_size_received] == 16_777_215
    assert opts[:reset_idle_timeout_on_send]
  end

  test "edge gRPC adapter opts allow bounded operator overrides" do
    System.put_env("GATEWAY_GRPC_MAX_CONCURRENT_STREAMS", "32")
    System.put_env("GATEWAY_GRPC_MAX_FRAME_SIZE_BYTES", "1048576")

    opts = GatewayApplication.edge_grpc_adapter_opts(:credential)

    assert opts[:max_concurrent_streams] == 32
    assert opts[:max_frame_size_received] == 1_048_576
  end

  test "edge gRPC adapter opts reject invalid overrides" do
    System.put_env("GATEWAY_GRPC_MAX_CONNECTIONS", "nope")
    System.put_env("GATEWAY_GRPC_IDLE_TIMEOUT_MS", "0")

    opts = GatewayApplication.edge_grpc_adapter_opts(:credential)

    assert opts[:max_connections] == 1_000
    assert opts[:idle_timeout] == 30_000
  end
end
