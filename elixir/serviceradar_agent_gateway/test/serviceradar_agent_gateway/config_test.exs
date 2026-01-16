defmodule ServiceRadarAgentGateway.ConfigTest do
  @moduledoc """
  Tests for agent gateway configuration.

  In the tenant-instance architecture, Config stores only the gateway's own identity
  (gateway_id, domain, capabilities). Tenant context flows through each request via mTLS.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.Config

  describe "setup/1" do
    test "stores gateway identity in persistent_term" do
      # Use unique key to avoid conflicts with other tests
      Config.setup(
        gateway_id: "test-gw-1",
        domain: "test-domain"
      )

      assert Config.gateway_id() == "test-gw-1"
      assert Config.domain() == "test-domain"
      assert Config.capabilities() == []
    end

    test "stores optional capabilities" do
      Config.setup(
        gateway_id: "test-gw-2",
        domain: "test-domain",
        capabilities: [:sweep, :snmp]
      )

      assert Config.capabilities() == [:sweep, :snmp]
    end

    test "requires gateway_id" do
      assert_raise KeyError, fn ->
        Config.setup(domain: "test-domain")
      end
    end

    test "requires domain" do
      assert_raise KeyError, fn ->
        Config.setup(gateway_id: "test-gw-3")
      end
    end
  end

  describe "get/1" do
    test "returns specific config value by key" do
      Config.setup(
        gateway_id: "test-gw-4",
        domain: "test-domain"
      )

      assert Config.get(:gateway_id) == "test-gw-4"
      assert Config.get(:domain) == "test-domain"
    end

    test "returns nil for missing keys" do
      Config.setup(
        gateway_id: "test-gw-5",
        domain: "test-domain"
      )

      assert Config.get(:nonexistent) == nil
    end
  end
end
