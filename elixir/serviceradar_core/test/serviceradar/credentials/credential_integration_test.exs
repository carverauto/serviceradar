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

  test "builds broker grants and plugin params from declarative templates" do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    rule = %{
      id: "rule-1",
      auth_method: "api_token",
      metadata: %{
        "purposes" => ["device_inventory"],
        "credential_broker_ttl_seconds" => 45,
        "timeout_ms" => 12_000
      }
    }

    assert {:ok, consumer} =
             CredentialIntegration.consumer_for_rule(profile, rule, "device_inventory")

    assert {:ok, {grant_attrs, extras}} =
             CredentialIntegration.grant_spec(
               consumer,
               rule,
               "secret-1",
               "agent-1",
               nil
             )

    assert extras == %{}
    assert grant_attrs.credential_rule_id == "rule-1"
    assert grant_attrs.grant_type == "example_api"
    assert grant_attrs.consumer_kind == :plugin
    assert grant_attrs.consumer_id == "example-network-inventory"
    assert grant_attrs.purpose == "device_inventory"
    assert grant_attrs.agent_id == "agent-1"
    assert grant_attrs.resolution_location == :agent
    assert grant_attrs.ttl_seconds == 45
    assert grant_attrs.allowed_methods == ["GET"]
    assert grant_attrs.allowed_paths == ["/api/devices"]
    assert grant_attrs.allowed_ports == [443]
    assert grant_attrs.secret_ref == "credentialref:network-credential-secret:secret-1"

    grant_payload = %{"grant_id" => "grant-1", "expires_at" => "2026-07-21T12:00:00Z"}

    assert {:ok, params} =
             CredentialIntegration.params_template(
               consumer,
               rule,
               "secret-1",
               grant_payload,
               nil
             )

    assert params["credential_broker"] == grant_payload
    assert params["credential_secret_ref"] == grant_attrs.secret_ref
    assert params["credential_rule_id"] == "rule-1"
    assert params["timeout_ms"] == 12_000
  end

  test "public usernames are requested only when a package template declares them" do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    assert {:ok, inventory_consumer} =
             CredentialIntegration.consumer_for_rule(
               profile,
               %{auth_method: "api_token"},
               "device_inventory"
             )

    assert {:ok, config_consumer} =
             CredentialIntegration.consumer_for_rule(
               profile,
               %{auth_method: "username_password"},
               "configuration_read"
             )

    refute CredentialIntegration.requires_public_username?(inventory_consumer)
    assert CredentialIntegration.requires_public_username?(config_consumer)
  end
end
