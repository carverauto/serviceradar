defmodule ServiceRadarObjectStorage.ConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadarObjectStorage, as: Storage

  @config %{
    host: "127.0.0.1",
    port: 9000,
    region: "test-region",
    bucket: "synthetic-recordings",
    access_key: "SYNTHETICACCESS",
    secret_key: "synthetic-secret-not-a-credential",
    session_token: nil,
    tls: false,
    concurrency: 1,
    buffer_size: 16_384
  }

  test "unsupported settings are rejected instead of silently selecting native defaults" do
    for {key, value} <- [
          pin_buffers: false,
          proxy: "http://proxy.example.test:3128",
          timeout_ms: 1000
        ] do
      assert {:error, :bad_config} = Storage.open(Map.put(@config, key, value))
    end
  end

  test "malformed maps and unsafe resource or transport settings fail before initialization" do
    for config <- [
          nil,
          [],
          Map.delete(@config, :tls),
          @config |> Map.delete(:tls) |> Map.put(:unknown, true),
          Map.put(@config, :tls, "false"),
          Map.put(@config, :concurrency, 0),
          Map.put(@config, :concurrency, 17),
          Map.merge(@config, %{concurrency: 16, buffer_size: 16_777_216}),
          Map.put(@config, :buffer_size, 8191),
          Map.put(@config, :buffer_size, -1),
          Map.put(@config, :port, 0),
          Map.put(@config, :port, 65_536),
          Map.put(@config, :host, "storage.example.test")
        ] do
      assert {:error, :bad_config} = Storage.open(config)
    end
  end
end
