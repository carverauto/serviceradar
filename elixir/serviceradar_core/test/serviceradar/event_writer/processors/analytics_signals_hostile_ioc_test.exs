defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsHostileIocTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

  test "emits hostile IOC on a vulnerable service as a detection finding" do
    payload = %{
      "event_id" => "hostile-ioc-vuln:sr:host-1:203.0.113.9:CVE-2024-6387",
      "signal_type" => "inventory",
      "event_type" => "hostile_ioc_vulnerable_service",
      "timestamp" => "2026-08-15T12:00:00Z",
      "severity" => "Critical",
      "device_uid" => "sr:host-1",
      "cve" => "CVE-2024-6387",
      "package" => %{"name" => "openssh-server"},
      "hostile_ip" => "203.0.113.9",
      "dst_ip" => "10.0.0.8",
      "dst_port" => 22,
      "comm" => "sshd",
      "message" => "Hostile IP 203.0.113.9 connected to openssh-server (CVE-2024-6387)"
    }

    row =
      AnalyticsSignals.parse_message(%{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "signals.analytics.inventory.hostile_ioc_vulnerable_service",
          received_at: DateTime.utc_now()
        }
      })

    assert row
    assert row.class_uid == 2004
    assert row.category_uid == 2
    assert row.type_uid == 200_401
    assert row.severity_id == 5
    assert row.severity == "Critical"
    assert row.device == %{"uid" => "sr:host-1"}
    assert row.src_endpoint == %{"ip" => "203.0.113.9"}
    assert row.dst_endpoint == %{"ip" => "10.0.0.8", "port" => 22}
    assert row.metadata["primary_domain"] == "security"
    assert row.metadata["service_radar"]["ocsf_class"] == "detection_finding"
    assert row.metadata["hostile_ioc_vulnerable_service"]["cve"] == "CVE-2024-6387"
    assert "security" in row.metadata["signal_domains"]
  end

  test "withholds a hostile IOC finding without a device uid" do
    row =
      AnalyticsSignals.parse_message(%{
        data:
          Jason.encode!(%{
            "event_id" => "hostile-ioc-vuln:missing",
            "signal_type" => "inventory",
            "event_type" => "hostile_ioc_vulnerable_service",
            "hostile_ip" => "203.0.113.9"
          }),
        metadata: %{
          subject: "signals.analytics.inventory.hostile_ioc_vulnerable_service",
          received_at: DateTime.utc_now()
        }
      })

    assert row == nil
  end
end
