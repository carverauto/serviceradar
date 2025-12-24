defmodule ServiceRadar.SPIFFETest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SPIFFE

  describe "parse_spiffe_id/1" do
    test "parses valid SPIFFE ID with partition" do
      spiffe_id = "spiffe://serviceradar.local/poller/partition-1/poller-001"

      assert {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)
      assert parsed.trust_domain == "serviceradar.local"
      assert parsed.node_type == :poller
      assert parsed.partition_id == "partition-1"
      assert parsed.node_id == "poller-001"
    end

    test "parses valid SPIFFE ID without partition" do
      spiffe_id = "spiffe://serviceradar.local/core/core-001"

      assert {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)
      assert parsed.trust_domain == "serviceradar.local"
      assert parsed.node_type == :core
      assert parsed.partition_id == "default"
      assert parsed.node_id == "core-001"
    end

    test "parses agent SPIFFE ID" do
      spiffe_id = "spiffe://serviceradar.local/agent/partition-1/agent-001"

      assert {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)
      assert parsed.node_type == :agent
    end

    test "returns error for invalid URI prefix" do
      assert {:error, :invalid_spiffe_uri} = SPIFFE.parse_spiffe_id("https://example.com/path")
    end

    test "returns error for unknown node type" do
      spiffe_id = "spiffe://serviceradar.local/unknown/partition-1/node-001"

      assert {:error, {:unknown_node_type, "unknown"}} = SPIFFE.parse_spiffe_id(spiffe_id)
    end

    test "returns error for invalid path format" do
      spiffe_id = "spiffe://serviceradar.local"

      assert {:error, :invalid_spiffe_path} = SPIFFE.parse_spiffe_id(spiffe_id)
    end
  end

  describe "build_spiffe_id/3" do
    test "builds SPIFFE ID with default trust domain" do
      result = SPIFFE.build_spiffe_id(:poller, "partition-1", "poller-001")

      assert result == "spiffe://serviceradar.local/poller/partition-1/poller-001"
    end

    test "builds SPIFFE ID with custom trust domain" do
      result = SPIFFE.build_spiffe_id(:agent, "partition-2", "agent-005", trust_domain: "custom.local")

      assert result == "spiffe://custom.local/agent/partition-2/agent-005"
    end

    test "builds core node SPIFFE ID" do
      result = SPIFFE.build_spiffe_id(:core, "default", "web-001")

      assert result == "spiffe://serviceradar.local/core/default/web-001"
    end
  end

  describe "authorized?/2" do
    test "returns true for matching node type and trust domain" do
      spiffe_id = "spiffe://serviceradar.local/poller/partition-1/poller-001"

      assert SPIFFE.authorized?(spiffe_id, :poller) == true
    end

    test "returns false for non-matching node type" do
      spiffe_id = "spiffe://serviceradar.local/poller/partition-1/poller-001"

      assert SPIFFE.authorized?(spiffe_id, :agent) == false
    end

    test "returns false for non-matching trust domain" do
      spiffe_id = "spiffe://other-domain.local/poller/partition-1/poller-001"

      assert SPIFFE.authorized?(spiffe_id, :poller) == false
    end

    test "returns false for invalid SPIFFE ID" do
      assert SPIFFE.authorized?("invalid", :poller) == false
    end
  end

  describe "cert_dir/0" do
    test "returns default cert directory" do
      assert SPIFFE.cert_dir() == "/etc/serviceradar/certs"
    end
  end

  describe "certs_available?/0" do
    test "returns false when certs don't exist" do
      # Default cert dir won't exist in test environment
      assert SPIFFE.certs_available?() == false
    end
  end

  describe "ssl_dist_opts/1" do
    test "returns error when certs don't exist" do
      assert {:error, {:cert_not_found, _}} = SPIFFE.ssl_dist_opts()
    end

    # Note: mode validation happens inside the specific mode handler
    # so with filesystem mode (default), we get cert not found first
    test "returns error when certs are missing in filesystem mode" do
      assert {:error, {:cert_not_found, _}} = SPIFFE.ssl_dist_opts()
    end
  end
end
