defmodule ServiceRadar.Observability.LogPromotionParserTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.LogPromotionParser

  test "parses syslog-style processed payloads" do
    payload =
      Jason.encode!(%{
        "_remote_addr" => "default:23.138.124.17",
        "host" => "tonka01",
        "level" => 3,
        "severity" => "Unknown",
        "short_message" => "tonka01 bgpd[2384]: [P3GYW-PBKQG][EC 33554466] 2605:8400:ff:142::",
        "timestamp" => 1_770_074_023,
        "version" => "1.1"
      })

    [log] = LogPromotionParser.parse_payload(payload, "logs.syslog.processed")

    assert log.service_name == "tonka01"
    assert log.body =~ "tonka01 bgpd"
    assert log.severity_text == "INFO"
    assert log.severity_number == 11
    assert %DateTime{} = log.timestamp

    assert get_in(log.attributes, ["serviceradar", "ingest", "subject"]) ==
             "logs.syslog.processed"
  end

  test "parses otel processed log arrays" do
    payload =
      Jason.encode!([
        %{
          "attributes" => %{"message_count" => "50"},
          "body" => "ProcessBatch called",
          "observed_time_unix_nano" => 1_770_095_683_106_019_230,
          "resource" => %{
            "service.name" => "serviceradar-db-event-writer",
            "service.version" => "1.0.0"
          },
          "resource_attributes" => %{
            "service.name" => "serviceradar-db-event-writer",
            "service.version" => "1.0.0"
          },
          "scope" => "db-writer-service",
          "scope_name" => "db-writer-service",
          "service_name" => "serviceradar-db-event-writer",
          "service_version" => "1.0.0",
          "severity_number" => 9,
          "severity_text" => "info",
          "timestamp" => 1_770_095_683_000_000_000,
          "trace_flags" => 0
        }
      ])

    [log] = LogPromotionParser.parse_payload(payload, "logs.otel.processed")

    assert log.service_name == "serviceradar-db-event-writer"
    assert log.body == "ProcessBatch called"
    assert log.severity_text == "INFO"
    assert log.severity_number == 11
    assert %DateTime{} = log.timestamp
  end
end
