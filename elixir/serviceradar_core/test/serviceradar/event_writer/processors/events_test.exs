defmodule ServiceRadar.EventWriter.Processors.EventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Events

  describe "table_name/0" do
    test "returns correct table name" do
      assert Events.table_name() == "events"
    end
  end

  describe "parse_message/1" do
    test "parses CloudEvents format" do
      json_data = Jason.encode!(%{
        "specversion" => "1.0",
        "id" => "event-123",
        "source" => "test/source",
        "type" => "test.event.created",
        "time" => "2024-01-15T10:30:00Z",
        "datacontenttype" => "application/json",
        "subject" => "test-subject",
        "data" => %{"message" => "Hello World"}
      })

      message = %{data: json_data, metadata: %{}}
      result = Events.parse_message(message)

      assert result.specversion == "1.0"
      assert result.id == "event-123"
      assert result.source == "test/source"
      assert result.type == "test.event.created"
      assert result.datacontenttype == "application/json"
      assert result.subject == "test-subject"
      assert result.short_message == "Hello World"
      assert %DateTime{} = result.event_timestamp
    end

    test "parses GELF format" do
      json_data = Jason.encode!(%{
        "version" => "1.1",
        "host" => "test-host",
        "short_message" => "Test log message",
        "timestamp" => 1705315800.123456,
        "level" => 6,
        "_remote_addr" => "192.168.1.100"
      })

      message = %{data: json_data, metadata: %{}}
      result = Events.parse_message(message)

      assert result.version == "1.1"
      assert result.host == "test-host"
      assert result.short_message == "Test log message"
      assert result.level == 6
      assert result.severity == "info"
      assert result.remote_addr == "192.168.1.100"
      assert %DateTime{} = result.event_timestamp
    end

    test "generates event id if not provided" do
      json_data = Jason.encode!(%{
        "source" => "test",
        "type" => "test.event"
      })

      message = %{data: json_data, metadata: %{}}
      result = Events.parse_message(message)

      assert result.id != nil
      assert String.length(result.id) > 0
    end

    test "handles string severity levels" do
      test_cases = [
        {"emergency", 0},
        {"alert", 1},
        {"critical", 2},
        {"error", 3},
        {"warning", 4},
        {"notice", 5},
        {"info", 6},
        {"debug", 7}
      ]

      for {severity_str, expected_level} <- test_cases do
        json_data = Jason.encode!(%{
          "level" => severity_str,
          "short_message" => "test"
        })

        message = %{data: json_data, metadata: %{}}
        result = Events.parse_message(message)

        assert result.level == expected_level,
               "Expected level #{expected_level} for severity '#{severity_str}', got #{result.level}"
      end
    end

    test "extracts message from various fields" do
      # Test short_message
      result1 = Events.parse_message(%{
        data: Jason.encode!(%{"short_message" => "from short_message"}),
        metadata: %{}
      })
      assert result1.short_message == "from short_message"

      # Test message
      result2 = Events.parse_message(%{
        data: Jason.encode!(%{"message" => "from message"}),
        metadata: %{}
      })
      assert result2.short_message == "from message"

      # Test msg
      result3 = Events.parse_message(%{
        data: Jason.encode!(%{"msg" => "from msg"}),
        metadata: %{}
      })
      assert result3.short_message == "from msg"

      # Test from data.message
      result4 = Events.parse_message(%{
        data: Jason.encode!(%{"data" => %{"message" => "from data.message"}}),
        metadata: %{}
      })
      assert result4.short_message == "from data.message"
    end

    test "handles floating point GELF timestamps" do
      # GELF timestamp with microseconds
      gelf_timestamp = 1705315800.123456

      json_data = Jason.encode!(%{
        "timestamp" => gelf_timestamp,
        "short_message" => "test"
      })

      message = %{data: json_data, metadata: %{}}
      result = Events.parse_message(message)

      assert %DateTime{} = result.event_timestamp
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not valid json", metadata: %{}}
      result = Events.parse_message(message)

      assert result == nil
    end
  end
end
