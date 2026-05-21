defmodule ServiceRadar.Credentials.NetworkCredentialRuleTestPlanTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.NetworkCredentialRuleTestPlan

  defmodule FakePreviewer do
    @moduledoc false

    def preview_rule(_rule, _opts) do
      {:ok,
       %{
         matched_devices: 3,
         scoped_devices: 1,
         agents: [%{agent_id: "agent-a", device_count: 1}],
         sample_devices: [
           %{
             "uid" => "device-1",
             "agent_id" => "agent-a",
             "ip" => "192.0.2.10",
             "hostname" => "pve-a"
           }
         ],
         conflicts: []
       }}
    end
  end

  defmodule EmptyPreviewer do
    @moduledoc false

    def preview_rule(_rule, _opts) do
      {:ok,
       %{
         matched_devices: 0,
         scoped_devices: 0,
         agents: [],
         sample_devices: [],
         conflicts: []
       }}
    end
  end

  test "proxmox_api_test builds redacted command plan from preview target" do
    rule = %{
      id: "rule-1",
      provider: "proxmox",
      auth_method: :proxmox_api_token,
      secret_id: "018f3f56-1111-7222-8333-123456789abc",
      target_query: "in:devices metadata.proxmox_candidate:true",
      tls_policy: :skip_verify,
      metadata: %{"timeout_ms" => 45_000, "test_ttl_seconds" => 180}
    }

    assert {:ok, plan} =
             NetworkCredentialRuleTestPlan.proxmox_api_test(rule,
               previewer: FakePreviewer,
               actor: %{id: "system"}
             )

    assert plan.command_type == "proxmox.credential_test"
    assert plan.agent_id == "agent-a"
    assert plan.required_capability == "http"
    assert plan.ttl_seconds == 180
    assert plan.context.credential_rule_id == "rule-1"
    assert plan.context.device_uid == "device-1"

    assert plan.payload["schema"] == "serviceradar.proxmox_credential_test.v1"

    assert plan.payload["credential_broker"]["schema"] ==
             "serviceradar.edge_credential_broker_grant.v1"

    assert is_binary(plan.payload["credential_broker"]["grant_id"])

    assert {:ok, _expires_at, 0} =
             DateTime.from_iso8601(plan.payload["credential_broker"]["expires_at"])

    assert plan.payload["credential_broker"]["credential_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    assert plan.payload["credential_broker"]["target"] == %{
             "device_uid" => "device-1",
             "base_url" => "https://192.0.2.10:8006",
             "kind" => "device",
             "id" => "device-1",
             "agent_id" => "agent-a"
           }

    assert plan.payload["credential_broker"]["allow"] == %{
             "methods" => ["GET"],
             "paths" => ["/api2/json/version", "/api2/json/nodes"],
             "hosts" => ["192.0.2.10"]
           }

    assert plan.payload["target"] == %{
             "device_uid" => "device-1",
             "base_url" => "https://192.0.2.10:8006",
             "hostname" => "pve-a",
             "ip" => "192.0.2.10",
             "kind" => "device",
             "id" => "device-1",
             "agent_id" => "agent-a"
           }

    assert plan.payload["tls"] == %{"insecure_skip_verify" => true}
    assert plan.payload["timeout_ms"] == 45_000

    refute inspect(plan) =~ "test-token"
    assert plan.payload["credential_broker"]["inject"]["scheme"] == "PVEAPIToken"
    refute Map.has_key?(plan.payload, "api_token")
  end

  test "proxmox_api_test rejects unsupported providers and empty previews" do
    unsupported = %{
      id: "rule-1",
      provider: "snmp",
      auth_method: :proxmox_api_token,
      secret_id: "secret",
      target_query: "in:devices"
    }

    assert {:error, :unsupported_provider} =
             NetworkCredentialRuleTestPlan.proxmox_api_test(unsupported,
               previewer: FakePreviewer
             )

    empty_rule = %{unsupported | provider: "proxmox"}

    assert {:error, :no_scoped_target} =
             NetworkCredentialRuleTestPlan.proxmox_api_test(empty_rule,
               previewer: EmptyPreviewer
             )
  end
end
