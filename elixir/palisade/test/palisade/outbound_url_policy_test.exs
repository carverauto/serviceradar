defmodule Palisade.OutboundURLPolicyTest do
  @moduledoc """
  Coverage for the SSRF-defense outbound URL policy.

  Tests use literal IP addresses to avoid DNS resolution at test
  time.
  """
  use ExUnit.Case, async: true

  alias Palisade.OutboundURLPolicy

  describe "validate_https_public_url/1 — scheme" do
    test "https is allowed" do
      assert {:ok, %URI{scheme: "https"}} =
               OutboundURLPolicy.validate_https_public_url("https://1.1.1.1/foo")
    end

    test "http is rejected" do
      assert {:error, :disallowed_scheme} =
               OutboundURLPolicy.validate_https_public_url("http://1.1.1.1/foo")
    end

    test "ftp / file / javascript / data are rejected" do
      for scheme <- ~w(ftp file javascript data) do
        assert {:error, _} =
                 OutboundURLPolicy.validate_https_public_url("#{scheme}://1.1.1.1/foo")
      end
    end

    test "case-insensitive scheme" do
      assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("HTTPS://1.1.1.1/foo")
    end
  end

  describe "validate_https_public_url/1 — invalid input" do
    test "empty / nil / non-binary" do
      assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url("")
      assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url(nil)
      assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url(:atom)
      assert {:error, :invalid_url} = OutboundURLPolicy.validate_https_public_url(42)
    end

    test "missing scheme or host" do
      assert {:error, _} = OutboundURLPolicy.validate_https_public_url("just-a-path")
      assert {:error, _} = OutboundURLPolicy.validate_https_public_url("https://")
    end
  end

  describe "validate_https_public_url/1 — private/loopback IPv4 literals" do
    test "10.0.0.0/8 (private)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://10.1.2.3/foo")
    end

    test "172.16.0.0/12 (private)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://172.20.5.6/foo")
    end

    test "192.168.0.0/16 (private)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://192.168.1.1/foo")
    end

    test "127.0.0.0/8 (loopback)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://127.0.0.1/foo")

      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://127.5.5.5/foo")
    end

    test "169.254.0.0/16 (link-local / cloud metadata)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url(
                 "https://169.254.169.254/latest/meta-data/"
               )
    end

    test "special-use, CGNAT, multicast, and reserved ranges" do
      for url <- [
            "https://0.0.0.0/foo",
            "https://100.64.0.1/foo",
            "https://192.0.2.1/foo",
            "https://198.18.0.1/foo",
            "https://203.0.113.1/foo",
            "https://224.0.0.1/foo",
            "https://240.0.0.1/foo"
          ] do
        assert {:error, :disallowed_host} = OutboundURLPolicy.validate_https_public_url(url)
      end
    end
  end

  describe "validate_https_public_url/1 — loopback/link-local IPv6 literals" do
    test "::1 (loopback)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[::1]/foo")
    end

    test ":: (unspecified)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[::]/foo")
    end

    test "fe80::/10 (link-local)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[fe80::1]/foo")
    end

    test "fc00::/7 (unique-local)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[fc00::1]/foo")

      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[fd00::1]/foo")
    end

    test "ff00::/8 (multicast)" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[ff00::1]/foo")
    end

    test "IPv4-mapped IPv6 literals are checked against the embedded IPv4 address" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://[::ffff:169.254.169.254]/")

      assert {:ok, _} =
               OutboundURLPolicy.validate_https_public_url("https://[::ffff:1.1.1.1]/")
    end
  end

  describe "validate_https_public_url/2 - port allowlist" do
    test "default allowlist accepts implicit and explicit 443" do
      assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://1.1.1.1/foo")
      assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:443/foo")
    end

    test "default allowlist rejects non-standard ports" do
      assert {:error, :disallowed_port} =
               OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:8443/foo")
    end

    test "callers can explicitly allow non-standard HTTPS ports" do
      assert {:ok, _} =
               OutboundURLPolicy.validate_https_public_url("https://1.1.1.1:8443/foo",
                 allowed_ports: [443, 8443]
               )
    end
  end

  describe "validate_https_public_url/1 — hostname blocks" do
    test "localhost" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://localhost/foo")
    end

    test "localhost.localdomain" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://localhost.localdomain/foo")
    end

    test "mDNS *.local" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://idp.local/foo")

      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://printer.local/metadata")
    end

    test "case-insensitive hostname blocks" do
      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://LOCALHOST/foo")

      assert {:error, :disallowed_host} =
               OutboundURLPolicy.validate_https_public_url("https://Server.LOCAL/foo")
    end
  end

  describe "validate_https_public_url/1 — accepts public IPv4 literals" do
    test "1.1.1.1 (Cloudflare)" do
      assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://1.1.1.1/foo")
    end

    test "8.8.8.8 (Google)" do
      assert {:ok, _} = OutboundURLPolicy.validate_https_public_url("https://8.8.8.8/foo")
    end
  end

  describe "private_or_loopback_ip? — direct unit checks" do
    alias Palisade.NetworkAddressPolicy, as: NAP

    test "IPv4 private + loopback CIDRs" do
      assert NAP.private_or_loopback_ip?({10, 0, 0, 1})
      assert NAP.private_or_loopback_ip?({172, 16, 0, 1})
      assert NAP.private_or_loopback_ip?({172, 31, 255, 255})
      assert NAP.private_or_loopback_ip?({192, 168, 0, 1})
      assert NAP.private_or_loopback_ip?({127, 0, 0, 1})
      assert NAP.private_or_loopback_ip?({169, 254, 169, 254})
    end

    test "IPv4 public addresses pass" do
      refute NAP.private_or_loopback_ip?({1, 1, 1, 1})
      refute NAP.private_or_loopback_ip?({8, 8, 8, 8})
      refute NAP.private_or_loopback_ip?({172, 15, 0, 1})
      refute NAP.private_or_loopback_ip?({172, 32, 0, 1})
    end

    test "IPv6 loopback / link-local / ULA" do
      assert NAP.private_or_loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1})
      assert NAP.private_or_loopback_ip?({0, 0, 0, 0, 0, 0, 0, 0})
      assert NAP.private_or_loopback_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert NAP.private_or_loopback_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "non-IP tuples / garbage rejected (fail-closed)" do
      assert NAP.private_or_loopback_ip?({1, 2, 3})
      assert NAP.private_or_loopback_ip?("not a tuple")
      assert NAP.private_or_loopback_ip?(nil)
    end
  end
end
