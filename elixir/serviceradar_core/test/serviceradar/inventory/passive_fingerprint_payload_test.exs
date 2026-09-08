defmodule ServiceRadar.Inventory.PassiveFingerprintPayloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.PassiveFingerprintPayload

  @tag :visibility
  test "normalizes flat TCP bridge metadata into nested metadata and OCSF os payloads" do
    metadata = %{
      "passive_fingerprint.source" => "passive-netprobe",
      "passive_fingerprint.profile_id" => "profile-1",
      "passive_fingerprint.profile_name" => "Linux Hosts",
      "passive_fingerprint.interface" => "eth0",
      "passive_fingerprint.observed_at" => "2026-05-27T12:00:00Z",
      "passive_fingerprint.tcp.signature" => "64240:64:1:60:M1460,S,T,N,W7",
      "passive_fingerprint.tcp.os_family" => "linux",
      "passive_fingerprint.tcp.os_name" => "Linux 5.x",
      "passive_fingerprint.tcp.confidence" => "0.92"
    }

    enriched = PassiveFingerprintPayload.enrich_metadata(metadata)
    tcp = enriched["passive_fingerprint"]["tcp"]

    assert tcp["p0f_signature"] == "64240:64:1:60:M1460,S,T,N,W7"
    assert tcp["signature"] == "64240:64:1:60:M1460,S,T,N,W7"
    assert tcp["os_family"] == "linux"
    assert tcp["os_name"] == "Linux 5.x"
    assert tcp["confidence"] == 0.92
    assert tcp["source"] == "passive-netprobe"
    assert tcp["profile_name"] == "Linux Hosts"
    assert tcp["interface"] == "eth0"
    assert tcp["observed_at"] == "2026-05-27T12:00:00Z"

    os = PassiveFingerprintPayload.enrich_os(%{}, enriched)

    assert os["passive_fingerprint"] == %{
             "family" => "linux",
             "version" => "Linux 5.x",
             "confidence" => 0.92,
             "source" => "serviceradar-license-clean",
             "observed_at" => "2026-05-27T12:00:00Z"
           }
  end

  @tag :visibility
  test "preserves nested future protocol payloads while adding known protocols" do
    metadata = %{
      "passive_fingerprint" => %{
        "future_protocol" => %{"signature" => "kept"},
        "tls" => %{"ja4" => "t13d1516h2_8daaf6152771_b0da82dd1658"}
      },
      "passive_fingerprint.http.server" => "apache"
    }

    enriched = PassiveFingerprintPayload.enrich_metadata(metadata)

    assert enriched["passive_fingerprint"]["future_protocol"] == %{"signature" => "kept"}
    assert enriched["passive_fingerprint"]["tls"]["ja4"] == "t13d1516h2_8daaf6152771_b0da82dd1658"
    assert enriched["passive_fingerprint"]["http"]["server"] == "apache"
  end

  @tag :visibility
  test "marks observed protocols when payload fields are redacted to empty values" do
    metadata = %{
      "passive_fingerprint" => %{
        "tls" => %{}
      },
      "passive_fingerprint.http.server" => " "
    }

    enriched = PassiveFingerprintPayload.enrich_metadata(metadata)

    assert enriched["passive_fingerprint"]["tls"] == %{"observed" => true}
    assert enriched["passive_fingerprint"]["http"] == %{"observed" => true}
    refute Map.has_key?(enriched["passive_fingerprint"], "tcp")
  end

  @tag :visibility
  test "keeps sparse OS evidence when only family is observed" do
    metadata = %{
      "passive_fingerprint" => %{
        "tcp" => %{"os_family" => "linux"}
      }
    }

    os = PassiveFingerprintPayload.enrich_os(%{}, metadata)

    assert os["passive_fingerprint"] == %{
             "family" => "linux",
             "source" => "serviceradar-license-clean"
           }
  end
end
