defmodule ServiceRadar.Policies.NetworkAddressPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Policies.NetworkAddressPolicy

  test "allows public hosts" do
    assert :ok = NetworkAddressPolicy.validate_public_host("example.com")
  end

  test "rejects invalid host values" do
    assert {:error, :invalid_url} = NetworkAddressPolicy.validate_public_host("")
    assert {:error, :invalid_url} = NetworkAddressPolicy.validate_public_host(nil)
  end

  test "rejects local and private hosts" do
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("localhost")
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("10.1.2.3")
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("192.168.10.8")
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("127.0.0.1")
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("169.254.1.8")
    assert {:error, :disallowed_host} = NetworkAddressPolicy.validate_public_host("host.local")
  end

  test "identifies private and loopback IP tuples" do
    assert NetworkAddressPolicy.private_or_loopback_ip?({10, 0, 0, 1})
    assert NetworkAddressPolicy.private_or_loopback_ip?({172, 16, 5, 9})
    assert NetworkAddressPolicy.private_or_loopback_ip?({192, 168, 0, 1})
    assert NetworkAddressPolicy.private_or_loopback_ip?({127, 0, 0, 1})
    assert NetworkAddressPolicy.private_or_loopback_ip?({169, 254, 1, 2})
    assert NetworkAddressPolicy.private_or_loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    assert NetworkAddressPolicy.private_or_loopback_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    refute NetworkAddressPolicy.private_or_loopback_ip?({8, 8, 8, 8})
  end

  test "matches IPs against configured CIDRs" do
    assert NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "10.0.0.0/8")
    assert NetworkAddressPolicy.cidr_contains?({192, 168, 1, 10}, "192.168.0.0/16")
    assert NetworkAddressPolicy.cidr_contains?({0xFD00, 0, 0, 0, 0, 0, 0, 1}, "fd00::/8")

    refute NetworkAddressPolicy.cidr_contains?({8, 8, 8, 8}, "10.0.0.0/8")
    refute NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "invalid")
  end

  test "matches IPs against any CIDR in a list" do
    assert NetworkAddressPolicy.ip_in_any_cidr?({10, 0, 0, 4}, ["192.168.0.0/16", "10.0.0.0/8"])
    refute NetworkAddressPolicy.ip_in_any_cidr?({8, 8, 8, 8}, ["192.168.0.0/16", "10.0.0.0/8"])
  end
end
