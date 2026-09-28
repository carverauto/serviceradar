defmodule ServiceRadar.Credentials.CredentialIntegrationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialIntegration
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  test "selects consumers and validates transport from an arbitrary profile" do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    rule = %{
      auth_method: "api_token",
      tls_policy: "verify",
      ssh_host_key_policy: "known_hosts",
      metadata: %{"purposes" => ["device_inventory"]}
    }

    assert CredentialIntegration.target_policy?(profile)
    assert CredentialIntegration.provider(profile) == "example-network"
    assert CredentialIntegration.purposes(profile) == ["device_inventory", "configuration_read"]
    assert CredentialIntegration.rule_has_purpose?(profile, rule, "device_inventory")

    assert {:ok, consumer} =
             CredentialIntegration.consumer_for_rule(profile, rule, "device_inventory")

    assert consumer["plugin_id"] == "example-network-inventory"
    assert :ok = CredentialIntegration.validate_rule(profile, consumer, rule)

    consumer_without_transport_constraints = Map.put(consumer, "constraints", %{})

    assert {:error, :credential_tls_policy_not_allowed} =
             CredentialIntegration.validate_rule(
               profile,
               consumer_without_transport_constraints,
               %{
                 rule
                 | tls_policy: "skip_verify"
               }
             )
  end
end
