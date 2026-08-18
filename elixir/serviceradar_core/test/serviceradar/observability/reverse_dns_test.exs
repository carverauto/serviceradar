defmodule ServiceRadar.Observability.ReverseDnsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ReverseDns

  test "parse_ip accepts IPv4, IPv6, and CIDR suffixes" do
    assert {:ok, {192, 168, 1, 1}} = ReverseDns.parse_ip("192.168.1.1")
    assert {:ok, {192, 168, 1, 1}} = ReverseDns.parse_ip(" 192.168.1.1/24 ")
    assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = ReverseDns.parse_ip("::1")
    assert {:error, "invalid_ip"} = ReverseDns.parse_ip("not-an-ip")
  end

  test "normalize_hostname strips trailing dots and rejects blanks" do
    assert {:ok, "router.lan"} = ReverseDns.normalize_hostname("router.lan.")
    assert {:ok, "router.lan"} = ReverseDns.normalize_hostname(~c"router.lan")
    assert {:error, "blank_hostname"} = ReverseDns.normalize_hostname("   ")
  end

  test "usable_hostname? rejects the IP itself" do
    assert ReverseDns.usable_hostname?("core-sw.farm.lan", "192.168.2.1")
    refute ReverseDns.usable_hostname?("192.168.2.1", "192.168.2.1")
    refute ReverseDns.usable_hostname?("", "192.168.2.1")
  end

  test "missing_or_ip_hostname? is true for blank or IP-shaped names" do
    assert ReverseDns.missing_or_ip_hostname?(nil, "10.0.0.1")
    assert ReverseDns.missing_or_ip_hostname?("", "10.0.0.1")
    assert ReverseDns.missing_or_ip_hostname?("10.0.0.1", "10.0.0.1")
    refute ReverseDns.missing_or_ip_hostname?("leaf-01", "10.0.0.1")
  end

  test "lookup_status honors an injected resolver and timeout" do
    resolver = fn _tuple -> {:ok, "edge-gw.example"} end

    assert {"edge-gw.example", "ok", nil} =
             ReverseDns.lookup_status("10.1.2.3", resolver: resolver, timeout_ms: 200)
  end

  test "lookup_status records resolver errors" do
    resolver = fn _tuple -> {:error, :nxdomain} end

    assert {nil, "error", error} =
             ReverseDns.lookup_status("10.1.2.3", resolver: resolver, timeout_ms: 200)

    assert error =~ "nxdomain"
  end
end
