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
end
