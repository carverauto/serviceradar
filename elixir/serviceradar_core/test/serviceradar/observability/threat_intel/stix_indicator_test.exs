defmodule ServiceRadar.Observability.ThreatIntel.StixIndicatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntel.StixIndicator

  test "extracts CIDRs from STIX IP comparison patterns" do
    pattern =
      "[ipv4-addr:value = '198.51.100.1' OR ipv4-addr:value ISSUBSET '203.0.113.0/24' OR ipv6-addr:value ISSUPERSET '2001:db8::/48']"

    assert StixIndicator.extract_cidrs(pattern) == [
             "198.51.100.1/32",
             "203.0.113.0/24",
             "2001:db8::/48"
           ]
  end

  test "extracts CIDRs from STIX IN patterns and skips unsupported values" do
    pattern =
      "[ipv4-addr:value IN ('192.0.2.9', '192.0.2.0/28') OR domain-name:value = 'example.invalid']"

    assert StixIndicator.extract_cidrs(pattern) == [
             "192.0.2.9/32",
             "192.0.2.0/28"
           ]
  end

  test "builds threat-intel attrs from STIX indicator objects" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    object = %{
      "type" => "indicator",
      "id" => "indicator--11111111-1111-4111-8111-111111111111",
      "name" => "Known C2 host",
      "created_by_ref" => "identity--22222222-2222-4222-8222-222222222222",
      "created" => "2026-04-26T10:00:00Z",
      "modified" => "2026-04-27T10:00:00Z",
      "valid_until" => "2026-05-27T10:00:00Z",
      "confidence" => 75,
      "pattern_type" => "stix",
      "pattern" => "[ipv4-addr:value = '198.51.100.77']"
    }

    assert [
             %{
               indicator: "198.51.100.77/32",
               indicator_type: "cidr",
               source: "identity--22222222-2222-4222-8222-222222222222",
               label: "Known C2 host",
               severity: nil,
               confidence: 75,
               first_seen_at: ~U[2026-04-26 10:00:00Z],
               last_seen_at: ~U[2026-04-27 10:00:00Z],
               expires_at: ~U[2026-05-27 10:00:00Z]
             }
           ] = StixIndicator.attrs_from_object(object, "taxii-feed", observed_at)
  end

  test "ignores non-STIX indicator objects and unsupported patterns" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    assert [] =
             StixIndicator.attrs_from_object(
               %{
                 "type" => "indicator",
                 "pattern_type" => "sigma",
                 "pattern" => "[ipv4-addr:value = '198.51.100.77']"
               },
               "taxii-feed",
               observed_at
             )

    assert [] =
             StixIndicator.attrs_from_object(
               %{
                 "type" => "indicator",
                 "pattern_type" => "stix",
                 "pattern" => "[domain-name:value = 'example.invalid']"
               },
               "taxii-feed",
               observed_at
             )
  end
end
