defmodule ServiceRadar.Automation.Northbound.PluginPackageContextTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Northbound.PluginPackageContext

  describe "own_integration_ids/2" do
    test "keeps only ids under the declared source prefixes, sorted and deduplicated" do
      values = [
        "example-sat:ut:ut-0002",
        "example-sat:ut:ut-0001",
        "example-sat:ut:ut-0001",
        "example-sat-router:rt-0003",
        "other-source:dev-0004",
        "example-satx:ut-0005",
        "example-sat:",
        "example-sat",
        nil
      ]

      assert PluginPackageContext.own_integration_ids(values, [
               "example-sat",
               "example-sat-router"
             ]) == [
               "example-sat-router:rt-0003",
               "example-sat:ut:ut-0001",
               "example-sat:ut:ut-0002"
             ]
    end

    test "a package without declared sources exposes no ids" do
      assert PluginPackageContext.own_integration_ids(["example-sat:ut:ut-0001"], []) == []
    end
  end

  test "package_rule_inputs/1 lists the rule inputs of package_rule requirements only" do
    requirements = %{
      "source_account" => %{
        "credential_source" => "assignment_schedule",
        "requirement" => "example_account"
      },
      "destination_account" => %{
        "credential_source" => "package_rule",
        "rule_input" => "destination_rule_id"
      },
      "api" => %{"credential_secret_input" => "api_secret_id"}
    }

    assert PluginPackageContext.package_rule_inputs(requirements) == ["destination_rule_id"]
    assert PluginPackageContext.package_rule_inputs(%{}) == []
  end
end
