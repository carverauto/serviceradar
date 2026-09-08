defmodule ServiceRadar.Identity.InterfaceIpAliasTest do
  @moduledoc """
  `:interface_ip` records an address seen on a device's own interface WITHOUT
  making it a merge key.

  The distinction is the whole point. Interface tables carry addresses that
  several devices legitimately share -- VRRP/HSRP virtual IPs, EVPN anycast
  gateways, cluster VIPs, and vendor internals such as Junos 10.0.0.4 --
  and `platform.merge_audit` already holds 212 alias-driven merges, including a
  chain on one address (A->B, then B->C a day later). Recording interface
  addresses as `:ip` would feed that mechanism.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.AliasEvents.AliasRecord

  defp record(metadata), do: AliasRecord.from_metadata(metadata)

  describe "AliasRecord parsing" do
    test "interface_ip_alias keys land in interface_ips, not ips" do
      rec =
        record(%{
          "_alias_last_seen_at" => "2026-08-23T12:00:00Z",
          "_alias_last_seen_ip" => "192.168.2.55",
          "ip_alias:192.168.2.55" => "2026-08-23T12:00:00Z",
          "interface_ip_alias:192.168.1.143" => "2026-08-23T12:00:00Z"
        })

      assert Map.has_key?(rec.ips, "192.168.2.55")
      assert Map.has_key?(rec.interface_ips, "192.168.1.143")

      refute Map.has_key?(rec.ips, "192.168.1.143"),
             "an interface address must never enter the identity alias map"
    end

    test "the two prefixes do not collide" do
      # "interface_ip_alias:" does not start with "ip_alias:", so existing
      # consumers that filter on the latter are unaffected. Asserted rather than
      # assumed, because a rename of either constant could silently promote
      # interface addresses to identity aliases.
      refute String.starts_with?("interface_ip_alias:10.0.0.1", "ip_alias:")
      refute String.starts_with?("ip_alias:10.0.0.1", "interface_ip_alias:")
    end
  end

  describe "the motivating case" do
    test "a switch's out-of-band address is recorded, but not as identity" do
      # switchcff8f2 (sr:f3f0e473) reports 192.168.1.143 on an `oob` interface.
      # It was previously minted as a phantom device, then orphaned entirely.
      rec =
        record(%{
          "_alias_last_seen_at" => "2026-08-23T12:00:00Z",
          "_alias_last_seen_ip" => "192.168.2.55",
          "ip_alias:192.168.2.55" => "2026-08-23T12:00:00Z",
          "interface_ip_alias:192.168.1.143" => "2026-08-23T12:00:00Z"
        })

      assert Map.keys(rec.ips) == ["192.168.2.55"]
      assert Map.keys(rec.interface_ips) == ["192.168.1.143"]
    end

    test "a shared vendor-internal address stays out of the identity map" do
      # 10.0.0.4 is a Junos internal that EVERY Junos box reports. It is the
      # address behind a real ip_alias_conflict merge in demo's merge_audit.
      rec =
        record(%{
          "_alias_last_seen_at" => "2026-08-23T12:00:00Z",
          "_alias_last_seen_ip" => "192.168.2.254",
          "ip_alias:192.168.2.254" => "2026-08-23T12:00:00Z",
          "interface_ip_alias:10.0.0.4" => "2026-08-23T12:00:00Z",
          "interface_ip_alias:128.0.0.1" => "2026-08-23T12:00:00Z"
        })

      refute Map.has_key?(rec.ips, "10.0.0.4")
      refute Map.has_key?(rec.ips, "128.0.0.1")
      assert map_size(rec.interface_ips) == 2
    end
  end

  describe "has_alias_metadata?/1" do
    test "recognises a record carrying only interface addresses" do
      assert AliasEvents.has_alias_metadata?(%{
               "interface_ip_alias:192.168.1.143" => "2026-08-23T12:00:00Z"
             })
    end

    test "still false for unrelated metadata" do
      refute AliasEvents.has_alias_metadata?(%{"vendor" => "Juniper"})
    end
  end

  describe "equality" do
    test "a change in interface addresses alone is detected" do
      base = %{
        "_alias_last_seen_at" => "2026-08-23T12:00:00Z",
        "_alias_last_seen_ip" => "192.168.2.55",
        "ip_alias:192.168.2.55" => "2026-08-23T12:00:00Z"
      }

      a = record(base)
      b = record(Map.put(base, "interface_ip_alias:192.168.1.143", "2026-08-23T12:00:00Z"))

      refute AliasRecord.equal?(a, b),
             "gaining an interface address is a real change and must not be silently equal"
    end
  end
end
