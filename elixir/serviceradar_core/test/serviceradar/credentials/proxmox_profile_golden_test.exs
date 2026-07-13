defmodule ServiceRadar.Credentials.ProxmoxProfileGoldenTest do
  @moduledoc """
  Golden-output guard for the Proxmox credential materializer.

  The expected `params_template` (and embedded broker grant payload) maps below
  use a deterministic grant issuer (fixed `id` + fixed `now`) and assert the
  secure, host-brokered output contract.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile

  @fixed_now ~U[2026-06-30 00:00:00Z]

  defmodule GoldenReconciler do
    @moduledoc false
    def reconcile(policy, input_defs, opts) do
      send(opts[:test_pid], {:policy, policy, input_defs})

      {:ok, %{resolved_inputs: 0, desired_assignments: 0, upserted: 0, unchanged: 0, disabled: 0}}
    end
  end

  defp deterministic_issuer do
    fn attrs ->
      grant =
        attrs
        |> CredentialBrokerGrant.issue_attrs(@fixed_now)
        |> Map.put(:id, "golden-grant")

      {:ok, grant}
    end
  end

  defp materialize(rule, purpose) do
    assert {:ok, _summary} =
             PluginAssignmentMaterializer.reconcile_rules(
               [rule],
               "agent-golden",
               %{id: "pkg-golden"},
               reconciler: GoldenReconciler,
               actor: %{id: "system"},
               grant_issuer: deterministic_issuer(),
               purpose: purpose,
               test_pid: self()
             )

    assert_receive {:policy, policy, input_defs}
    {policy, input_defs}
  end

  test "proxmox inventory template matches the verified-TLS golden output" do
    rule = %{
      id: "golden-rule",
      secret_id: "018f3f56-1111-7222-8333-123456789abc",
      purpose: :inventory_enrichment,
      target_query: "in:devices metadata.proxmox_candidate:true",
      tls_policy: :verify,
      updated_at: ~U[2026-05-06 19:30:00Z],
      metadata: %{
        "include_guests" => false,
        "timeout_ms" => 45_000,
        "interval_seconds" => 600,
        "timeout_seconds" => 45,
        "chunk_size" => 25,
        "auto_discovery_enabled" => true
      }
    }

    {policy, input_defs} = materialize(rule, :inventory_enrichment)

    assert policy.policy_id == "network-credential-rule:golden-rule"

    assert input_defs == [
             %{
               name: "targets",
               entity: "devices",
               query: "in:devices metadata.proxmox_candidate:true"
             }
           ]

    assert policy.params_template == %{
             "api_token_secret_ref" =>
               "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
             "auto_discovery_enabled" => true,
             "credential_broker" => %{
               "allow" => %{
                 "methods" => ["GET"],
                 "paths" => [
                   "/api2/json/version",
                   "/api2/json/cluster/status",
                   "/api2/json/nodes",
                   "/api2/json/nodes/*",
                   "/api2/json/cluster/resources"
                 ]
               },
               "consumer" => %{
                 "id" => "proxmox-inventory",
                 "kind" => "plugin",
                 "purpose" => "inventory_enrichment"
               },
               "credential_rule_id" => "golden-rule",
               "credential_secret_ref" =>
                 "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
               "expires_at" => "2026-06-30T00:05:00Z",
               "grant_id" => "golden-grant",
               "grant_type" => "proxmox_api_token",
               "inject" => %{
                 "name" => "Authorization",
                 "scheme" => "PVEAPIToken",
                 "type" => "http_header"
               },
               "resolution_location" => "agent",
               "schema" => "serviceradar.edge_credential_broker_grant.v1",
               "target" => %{"agent_id" => "agent-golden"},
               "ttl_seconds" => 300
             },
             "credential_rule_id" => "golden-rule",
             "include_guests" => false,
             "timeout_ms" => 45_000
           }
  end

  test "proxmox SSH console template matches the host-key-verified golden output" do
    rule = %{
      id: "console-rule",
      secret_id: "018f3f56-5555-7666-8777-123456789abc",
      purpose: :console_access,
      auth_method: :ssh_private_key,
      target_query: "in:devices metadata.proxmox_candidate:true",
      tls_policy: :verify,
      ssh_host_key_policy: :trust_on_first_use,
      updated_at: ~U[2026-05-06 19:30:00Z],
      metadata: %{"timeout_ms" => 20_000}
    }

    {policy, _input_defs} = materialize(rule, :console_access)

    assert policy.policy_id == "network-credential-rule:console-rule:console_access"

    assert policy.params_template == %{
             "credential_broker" => %{
               "auth_method" => "ssh_private_key",
               "consumer" => %{
                 "id" => "proxmox-console",
                 "kind" => "plugin",
                 "purpose" => "console_access"
               },
               "credential_rule_id" => "console-rule",
               "credential_secret_ref" =>
                 "credentialref:network-credential-secret:018f3f56-5555-7666-8777-123456789abc",
               "expires_at" => "2026-06-30T00:05:00Z",
               "grant_id" => "golden-grant",
               "grant_type" => "proxmox_console",
               "resolution_location" => "agent",
               "schema" => "serviceradar.edge_credential_broker_grant.v1",
               "target" => %{"agent_id" => "agent-golden"},
               "ttl_seconds" => 300
             },
             "credential_rule_id" => "console-rule",
             "credential_secret" =>
               "credentialref:network-credential-secret:018f3f56-5555-7666-8777-123456789abc",
             "ssh_host_key_policy" => "trust_on_first_use",
             "timeout_ms" => 20_000
           }
  end

  test "Proxmox API-token templates reject disabled TLS verification" do
    rule = %{
      id: "insecure-rule",
      auth_method: :proxmox_api_token,
      tls_policy: :skip_verify,
      ssh_host_key_policy: :known_hosts,
      metadata: %{}
    }

    assert {:error, :proxmox_tls_verification_required} =
             ProxmoxProfile.params_template(
               :inventory_enrichment,
               rule,
               "018f3f56-1111-7222-8333-123456789abc",
               %{grant: %{}}
             )

    assert {:error, :proxmox_tls_verification_required} =
             ProxmoxProfile.params_template(
               :console_access,
               rule,
               "018f3f56-1111-7222-8333-123456789abc",
               %{grant: %{}}
             )
  end

  test "Proxmox console templates reject credentials outside the closed auth set" do
    for auth_method <- [:username_password, :api_key, :certificate, :opaque] do
      rule = %{
        id: "unsupported-console-auth-rule",
        auth_method: auth_method,
        tls_policy: :verify,
        ssh_host_key_policy: :known_hosts,
        metadata: %{}
      }

      assert {:error, :unsupported_proxmox_console_auth_method} =
               ProxmoxProfile.params_template(
                 :console_access,
                 rule,
                 "018f3f56-1111-7222-8333-123456789abc",
                 %{grant: %{}}
               )
    end
  end

  test "inventory-only Proxmox API-token rules are not console eligible" do
    rule = %{
      id: "shared-proxmox-api-rule",
      secret_id: "secret-proxmox-api-shared",
      purpose: :inventory_enrichment,
      auth_method: :proxmox_api_token,
      target_query: "in:devices metadata.proxmox_candidate:true",
      tls_policy: :verify,
      updated_at: ~U[2026-05-06 19:30:00Z],
      metadata: %{}
    }

    refute ProxmoxProfile.rule_has_purpose?(
             rule,
             :console_access
           )
  end
end
