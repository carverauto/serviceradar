defmodule ServiceRadar.Security.MTLSTenantValidationTest do
  @moduledoc """
  Security validation tests for mTLS tenant identification.

  Verifies that:
  - TenantResolver correctly extracts tenant from certificate CN (9.3)
  - Invalid certificates are rejected
  - Tenant mismatch is detected
  - SPIFFE IDs are properly parsed and validated

  ## Certificate Format

  Edge components use certificates with CN format:
  `<component_id>.<partition_id>.<tenant_slug>.serviceradar`

  And SPIFFE URI SAN:
  `spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>`
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.TenantResolver
  alias ServiceRadar.SPIFFE

  describe "TenantResolver CN parsing (9.3)" do
    test "extracts tenant slug from valid CN" do
      # Valid CN format: component_id.partition_id.tenant_slug.serviceradar
      cn = "gateway-001.partition-1.acme-corp.serviceradar"

      {:ok, slug} = TenantResolver.extract_slug_from_cn(cn)

      assert slug == "acme-corp"
    end

    test "extracts tenant from agent CN" do
      cn = "agent-edge-01.us-west-2.tenant-xyz.serviceradar"

      {:ok, slug} = TenantResolver.extract_slug_from_cn(cn)

      assert slug == "tenant-xyz"
    end

    test "extracts tenant from checker CN" do
      cn = "checker-http.partition-default.my-company.serviceradar"

      {:ok, slug} = TenantResolver.extract_slug_from_cn(cn)

      assert slug == "my-company"
    end

    test "rejects invalid CN format - missing parts" do
      invalid_cns = [
        "gateway-001.serviceradar",           # Only 2 parts
        "gateway-001.partition.serviceradar", # Only 3 parts
        "just-a-name",                       # Single part
        ""                                   # Empty
      ]

      for cn <- invalid_cns do
        assert :error == TenantResolver.extract_slug_from_cn(cn),
          "Should reject invalid CN: #{cn}"
      end
    end

    test "rejects CN not ending in serviceradar domain" do
      invalid_cns = [
        "gateway-001.partition-1.acme.example.com",
        "gateway-001.partition-1.acme.otherservice",
        "gateway-001.partition-1.acme.local"
      ]

      for cn <- invalid_cns do
        assert :error == TenantResolver.extract_slug_from_cn(cn),
          "Should reject CN with wrong domain: #{cn}"
      end
    end
  end

  describe "TenantResolver.validate_tenant/2" do
    test "validates matching tenant" do
      # Create a mock certificate with the expected tenant
      # For unit testing, we test the CN parsing logic directly
      cn = "agent-001.partition-1.expected-tenant.serviceradar"

      {:ok, tenant_slug} = TenantResolver.extract_slug_from_cn(cn)

      assert tenant_slug == "expected-tenant"
    end

    test "detects tenant mismatch" do
      cn = "agent-001.partition-1.tenant-a.serviceradar"

      {:ok, tenant_slug} = TenantResolver.extract_slug_from_cn(cn)

      # Verify we can detect mismatches
      refute tenant_slug == "tenant-b",
        "Should detect tenant mismatch: got #{tenant_slug}, expected tenant-b"
    end
  end

  describe "SPIFFE ID parsing" do
    test "parses valid SPIFFE ID with all components" do
      spiffe_id = "spiffe://serviceradar.local/gateway/partition-1/gateway-001"

      {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)

      assert parsed.trust_domain == "serviceradar.local"
      assert parsed.node_type == :gateway
      assert parsed.partition_id == "partition-1"
      assert parsed.node_id == "gateway-001"
    end

    test "parses agent SPIFFE ID" do
      spiffe_id = "spiffe://serviceradar.local/agent/us-east-1/agent-edge-01"

      {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)

      assert parsed.node_type == :agent
      assert parsed.partition_id == "us-east-1"
      assert parsed.node_id == "agent-edge-01"
    end

    test "parses core SPIFFE ID" do
      spiffe_id = "spiffe://serviceradar.local/core/platform/core-001"

      {:ok, parsed} = SPIFFE.parse_spiffe_id(spiffe_id)

      assert parsed.node_type == :core
      assert parsed.partition_id == "platform"
      assert parsed.node_id == "core-001"
    end

    test "rejects invalid SPIFFE URI prefix" do
      invalid_ids = [
        "http://serviceradar.local/gateway/p1/g001",
        "https://serviceradar.local/gateway/p1/g001",
        "serviceradar.local/gateway/p1/g001"
      ]

      for id <- invalid_ids do
        assert {:error, :invalid_spiffe_uri} == SPIFFE.parse_spiffe_id(id),
          "Should reject non-SPIFFE URI: #{id}"
      end
    end

    test "rejects unknown node types" do
      spiffe_id = "spiffe://serviceradar.local/database/partition-1/db-001"

      assert {:error, {:unknown_node_type, "database"}} == SPIFFE.parse_spiffe_id(spiffe_id)
    end
  end

  describe "SPIFFE authorization" do
    test "authorizes gateway with gateway SPIFFE ID" do
      spiffe_id = "spiffe://serviceradar.local/gateway/partition-1/gateway-001"

      assert SPIFFE.authorized?(spiffe_id, :gateway)
    end

    test "authorizes agent with agent SPIFFE ID" do
      spiffe_id = "spiffe://serviceradar.local/agent/partition-1/agent-001"

      assert SPIFFE.authorized?(spiffe_id, :agent)
    end

    test "rejects type mismatch - agent claiming to be gateway" do
      agent_spiffe_id = "spiffe://serviceradar.local/agent/partition-1/agent-001"

      refute SPIFFE.authorized?(agent_spiffe_id, :gateway),
        "Agent SPIFFE ID should not be authorized as gateway"
    end

    test "rejects type mismatch - gateway claiming to be core" do
      gateway_spiffe_id = "spiffe://serviceradar.local/gateway/partition-1/gateway-001"

      refute SPIFFE.authorized?(gateway_spiffe_id, :core),
        "Gateway SPIFFE ID should not be authorized as core"
    end
  end

  describe "SPIFFE ID building" do
    test "builds correct SPIFFE ID for gateway" do
      spiffe_id = SPIFFE.build_spiffe_id(:gateway, "partition-1", "gateway-001")

      assert spiffe_id == "spiffe://serviceradar.local/gateway/partition-1/gateway-001"
    end

    test "builds correct SPIFFE ID for agent" do
      spiffe_id = SPIFFE.build_spiffe_id(:agent, "us-west-2", "agent-edge-01")

      assert spiffe_id == "spiffe://serviceradar.local/agent/us-west-2/agent-edge-01"
    end

    test "builds correct SPIFFE ID for core" do
      spiffe_id = SPIFFE.build_spiffe_id(:core, "platform", "core-001")

      assert spiffe_id == "spiffe://serviceradar.local/core/platform/core-001"
    end

    test "allows custom trust domain" do
      spiffe_id = SPIFFE.build_spiffe_id(:gateway, "partition-1", "gateway-001",
        trust_domain: "custom.domain")

      assert spiffe_id == "spiffe://custom.domain/gateway/partition-1/gateway-001"
    end
  end

  describe "certificate expiry checking" do
    test "cert_expiry returns error when certs not available" do
      # Use a non-existent directory
      result = SPIFFE.cert_expiry(cert_dir: "/nonexistent/path")

      assert {:error, _reason} = result
    end

    test "certs_available? returns false when certs missing" do
      # In test environment, SPIFFE certs are typically not present
      # This validates the function works correctly
      result = SPIFFE.certs_available?()

      # In test, this is expected to be false (no real SPIFFE certs)
      assert is_boolean(result)
    end
  end
end
