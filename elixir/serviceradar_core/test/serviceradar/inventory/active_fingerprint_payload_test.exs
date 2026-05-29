defmodule ServiceRadar.Inventory.ActiveFingerprintPayloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.ActiveFingerprintPayload

  @tag :visibility
  test "normalizes flat sweep-active fingerprint metadata" do
    metadata = %{
      "active_fingerprint.source" => "sweep_active",
      "active_fingerprint.observed_at" => "2026-05-28T12:00:00Z",
      "active_fingerprint.os.name" => "Ubuntu Linux",
      "active_fingerprint.os.version_range" => "22.04",
      "active_fingerprint.os.family" => "linux",
      "active_fingerprint.os.confidence" => "0.86",
      "active_fingerprint.recog.ssh.product" => "OpenSSH",
      "active_fingerprint.recog.ssh.version" => "8.9",
      "active_fingerprint.recog.ssh.os_family" => "linux",
      "active_fingerprint.recog.smtp.product" => "Postfix",
      "active_fingerprint.recog.ntp.product" => "ntpsec"
    }

    enriched = ActiveFingerprintPayload.enrich_metadata(metadata)

    assert enriched["active_fingerprint"]["os"] == %{
             "name" => "Ubuntu Linux",
             "version_range" => "22.04",
             "family" => "linux",
             "confidence" => 0.86,
             "source" => "serviceradar-sweep-active",
             "observed_at" => "2026-05-28T12:00:00Z"
           }

    assert enriched["active_fingerprint"]["recog"]["ssh"] == %{
             "product" => "OpenSSH",
             "version" => "8.9",
             "os_family" => "linux"
           }

    assert enriched["active_fingerprint"]["recog"]["smtp"] == %{"product" => "Postfix"}
    assert enriched["active_fingerprint"]["recog"]["ntp"] == %{"product" => "ntpsec"}

    os = ActiveFingerprintPayload.enrich_os(%{}, enriched)

    assert os["active_fingerprint"] == %{
             "name" => "Ubuntu Linux",
             "version_range" => "22.04",
             "family" => "linux",
             "confidence" => 0.86,
             "source" => "serviceradar-sweep-active",
             "observed_at" => "2026-05-28T12:00:00Z"
           }
  end

  @tag :visibility
  test "preserves nested active fingerprint data while adding new protocols" do
    metadata = %{
      "active_fingerprint" => %{
        "custom_axis" => %{"label" => "kept"},
        "recog" => %{"http" => %{"product" => "nginx"}}
      },
      "active_fingerprint.recog.ssh.product" => "OpenSSH"
    }

    enriched = ActiveFingerprintPayload.enrich_metadata(metadata)

    assert enriched["active_fingerprint"]["custom_axis"] == %{"label" => "kept"}
    assert enriched["active_fingerprint"]["recog"]["http"] == %{"product" => "nginx"}
    assert enriched["active_fingerprint"]["recog"]["ssh"] == %{"product" => "OpenSSH"}
  end

  @tag :visibility
  test "does not synthesize OS fingerprint metadata without OS evidence" do
    metadata = %{
      "hostname" => "router-1",
      "active_fingerprint.observed_at" => "2026-05-28T12:00:00Z"
    }

    assert ActiveFingerprintPayload.enrich_metadata(metadata) == metadata
    assert ActiveFingerprintPayload.enrich_os(%{}, metadata) == %{}
  end
end
