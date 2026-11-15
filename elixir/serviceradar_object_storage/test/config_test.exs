defmodule ServiceRadarObjectStorage.ConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadarObjectStorage, as: Storage
  alias ServiceRadarObjectStorage.Session

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

  test "Session call options reject unknown keys and invalid call timeouts before dispatch" do
    put_opts = %{no_clobber: true, encryption: :aes256, checksum: :none}
    expect = %{etag: nil, version: nil}

    assert {:error, :bad_config} = Session.put(:unused_server, "k", "v", put_opts, unknown: true)
    assert {:error, :bad_config} = Session.head(:unused_server, "k", expect, call_timeout: 0)
    assert {:error, :bad_config} = Session.get(:unused_server, "k", nil, expect, call_timeout: :bad)
  end
end
