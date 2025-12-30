defmodule ServiceRadar.EventWriter.ConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Config

  describe "enabled?/0" do
    test "returns false by default" do
      # Clear any existing env var
      System.delete_env("EVENT_WRITER_ENABLED")

      refute Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is 'true'" do
      System.put_env("EVENT_WRITER_ENABLED", "true")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is '1'" do
      System.put_env("EVENT_WRITER_ENABLED", "1")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is 'yes'" do
      System.put_env("EVENT_WRITER_ENABLED", "yes")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns false for other values" do
      System.put_env("EVENT_WRITER_ENABLED", "false")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      refute Config.enabled?()
    end
  end

  describe "default_streams/0" do
    test "returns list of default stream configurations" do
      streams = Config.default_streams()

      assert is_list(streams)
      assert length(streams) > 0

      # Check that expected streams are present
      stream_names = Enum.map(streams, & &1.name)
      assert "EVENTS" in stream_names
      assert "SNMP_TRAPS" in stream_names
      assert "OTEL_METRICS" in stream_names
      assert "OTEL_TRACES" in stream_names
      assert "LOGS" in stream_names
    end

    test "each stream has required fields" do
      for stream <- Config.default_streams() do
        assert Map.has_key?(stream, :name)
        assert Map.has_key?(stream, :subject)
        assert Map.has_key?(stream, :processor)
        assert Map.has_key?(stream, :batch_size)
        assert Map.has_key?(stream, :batch_timeout)
      end
    end

    test "stream processors are valid modules" do
      for stream <- Config.default_streams() do
        assert is_atom(stream.processor)
        # Processor module name should contain "Processors"
        assert String.contains?(Atom.to_string(stream.processor), "Processors")
      end
    end
  end

  describe "load/0" do
    test "returns Config struct" do
      config = Config.load()

      assert %Config{} = config
      assert is_boolean(config.enabled)
      assert is_map(config.nats)
      assert is_integer(config.batch_size)
      assert is_integer(config.batch_timeout)
      assert is_binary(config.consumer_name)
      assert is_list(config.streams)
    end

    test "loads default NATS configuration" do
      config = Config.load()

      assert config.nats.host == "localhost"
      assert config.nats.port == 4222
    end

    test "uses default batch settings" do
      config = Config.load()

      assert config.batch_size == 100
      assert config.batch_timeout == 1000
    end

    test "uses default consumer name" do
      config = Config.load()

      assert config.consumer_name == "serviceradar-event-writer"
    end

    test "parses NATS URL from environment" do
      System.put_env("EVENT_WRITER_NATS_URL", "nats://custom-host:5222")
      on_exit(fn -> System.delete_env("EVENT_WRITER_NATS_URL") end)

      config = Config.load()

      assert config.nats.host == "custom-host"
      assert config.nats.port == 5222
    end

    test "parses batch settings from environment" do
      System.put_env("EVENT_WRITER_BATCH_SIZE", "200")
      System.put_env("EVENT_WRITER_BATCH_TIMEOUT", "2000")
      on_exit(fn ->
        System.delete_env("EVENT_WRITER_BATCH_SIZE")
        System.delete_env("EVENT_WRITER_BATCH_TIMEOUT")
      end)

      config = Config.load()

      assert config.batch_size == 200
      assert config.batch_timeout == 2000
    end

    test "parses consumer name from environment" do
      System.put_env("EVENT_WRITER_CONSUMER_NAME", "custom-consumer")
      on_exit(fn -> System.delete_env("EVENT_WRITER_CONSUMER_NAME") end)

      config = Config.load()

      assert config.consumer_name == "custom-consumer"
    end
  end
end
