defmodule ServiceRadarWebNG.Plugins.CredentialCoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.CredentialCoverage

  @moduletag :db_free

  defp credential_rule(attrs) do
    Map.merge(
      %{
        id: "example-rule",
        name: "Example inventory",
        secret_id: "018f3f56-aaaa-7bbb-8ccc-123456789abc",
        enabled: true,
        priority: 100,
        provider: "example-network",
        auth_method: "api_token",
        purpose: "device_inventory",
        target_query: "in:devices vendor:Example",
        scope_type: :agent,
        scope_value: "agent-a",
        metadata: %{}
      },
      attrs
    )
  end

  describe "materialized_fields/1" do
    test "extracts annotated property names" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "host" => %{"type" => "string", "x-serviceradar-credential-materialized" => true},
          "scheme" => %{"type" => "string"}
        }
      }

      assert CredentialCoverage.materialized_fields(schema) == ["host"]
    end

    test "handles missing or non-map schemas" do
      assert CredentialCoverage.materialized_fields(nil) == []
      assert CredentialCoverage.materialized_fields(%{}) == []
    end
  end

  describe "coverage/3" do
    test "plugin ids outside approved package descriptors are not applicable" do
      opts = [integration_catalog: catalog()]
      assert CredentialCoverage.coverage("unrelated-plugin", "agent-a", opts) == :not_applicable
      assert CredentialCoverage.coverage(nil, "agent-a", opts) == :not_applicable
    end

    test "an enabled matching rule covers the agent with database-free inputs" do
      opts = [integration_catalog: catalog(), rules: [credential_rule(%{})]]

      assert {:ok, coverage} =
               CredentialCoverage.coverage("example-network-inventory", "agent-a", opts)

      assert coverage.state == :covered
      assert coverage.provider == "example-network"
      assert coverage.purpose == "device_inventory"
      assert coverage.rules == ["Example inventory"]
    end

    test "no matching rule leaves the agent uncovered" do
      opts = [integration_catalog: catalog(), rules: []]

      assert {:ok, coverage} =
               CredentialCoverage.coverage("example-network-inventory", "agent-a", opts)

      assert coverage.state == :uncovered
      assert coverage.rules == []
    end

    test "rules scoped to a different agent do not cover" do
      rule = credential_rule(%{scope_value: "agent-other"})
      opts = [integration_catalog: catalog(), rules: [rule]]

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("example-network-inventory", "agent-a", opts)
    end

    test "disabled rules do not cover" do
      rule = credential_rule(%{enabled: false})
      opts = [integration_catalog: catalog(), rules: [rule]]

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("example-network-inventory", "agent-a", opts)
    end

    test "rules for another provider do not leak into plugin coverage" do
      rule = credential_rule(%{provider: "different-provider"})
      opts = [integration_catalog: catalog(), rules: [rule]]

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("example-network-inventory", "agent-a", opts)
    end
  end

  describe "warning_message/2" do
    test "names provider, purpose, and agent for uncovered assignments" do
      coverage = %{
        state: :uncovered,
        provider: "example-network",
        purpose: "device_inventory"
      }

      message = CredentialCoverage.warning_message(coverage, "agent-a")

      assert message =~ "example-network"
      assert message =~ "device_inventory"
      assert message =~ "agent-a"
      assert message =~ "Settings -> Networks -> Credentials"
      assert message =~ "Do not paste passwords into the plugin form"
    end

    test "covered assignments produce no warning" do
      coverage = %{state: :covered, provider: "example-network", purpose: "device_inventory"}
      assert CredentialCoverage.warning_message(coverage, "agent-a") == nil
    end
  end

  defp catalog do
    %{
      credential_profiles: [
        %{
          "provider" => "example-network",
          "provisioning" => %{
            "mode" => "target_policy",
            "consumers" => [
              %{
                "purpose" => "device_inventory",
                "plugin_id" => "example-network-inventory",
                "auth_methods" => ["api_token"]
              }
            ]
          },
          "rule_defaults" => %{"auth_method" => "api_token"}
        }
      ],
      inventory_sources: []
    }
  end
end
