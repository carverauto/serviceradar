defmodule ServiceRadarWebNG.Plugins.CredentialCoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.CredentialCoverage

  defp camera_rule(attrs) do
    Map.merge(
      %{
        id: "cam-rule",
        name: "Protect HQ",
        secret_id: "018f3f56-aaaa-7bbb-8ccc-123456789abc",
        enabled: true,
        priority: 100,
        provider: "unifi-protect",
        auth_method: :api_key,
        purpose: :camera_inventory,
        target_query: "in:devices hostname:udm-*",
        scope_type: :agent,
        scope_value: "agent-cam",
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
    test "plugin ids outside the provider profiles are not applicable" do
      assert CredentialCoverage.coverage("dusk-checker", "agent-1") == :not_applicable
      assert CredentialCoverage.coverage(nil, "agent-1") == :not_applicable
    end

    test "an enabled matching rule covers the agent (rules injected, db-free)" do
      assert {:ok, coverage} =
               CredentialCoverage.coverage("unifi-protect-camera", "agent-cam", rules: [camera_rule(%{})])

      assert coverage.state == :covered
      assert coverage.provider == "unifi-protect"
      assert coverage.purpose == :camera_inventory
      assert coverage.rules == ["Protect HQ"]
    end

    test "no matching rule leaves the agent uncovered" do
      assert {:ok, coverage} =
               CredentialCoverage.coverage("unifi-protect-camera", "agent-cam", rules: [])

      assert coverage.state == :uncovered
      assert coverage.rules == []
    end

    test "rules scoped to a different agent do not cover" do
      rule = camera_rule(%{scope_value: "agent-other"})

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("unifi-protect-camera", "agent-cam", rules: [rule])
    end

    test "disabled rules do not cover" do
      rule = camera_rule(%{enabled: false})

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("unifi-protect-camera", "agent-cam", rules: [rule])
    end

    test "rules for another provider's plugin do not leak" do
      # A proxmox rule cannot cover a camera plugin.
      rule = camera_rule(%{provider: "proxmox"})

      assert {:ok, %{state: :uncovered}} =
               CredentialCoverage.coverage("unifi-protect-camera", "agent-cam", rules: [rule])
    end
  end

  describe "warning_message/2" do
    test "names provider, purpose, and agent for uncovered assignments" do
      coverage = %{state: :uncovered, provider: "unifi-protect", purpose: :camera_inventory}

      message = CredentialCoverage.warning_message(coverage, "agent-cam")

      assert message =~ "unifi-protect"
      assert message =~ "camera_inventory"
      assert message =~ "agent-cam"
    end

    test "covered assignments produce no warning" do
      coverage = %{state: :covered, provider: "unifi-protect", purpose: :camera_inventory}
      assert CredentialCoverage.warning_message(coverage, "agent-cam") == nil
    end
  end
end
