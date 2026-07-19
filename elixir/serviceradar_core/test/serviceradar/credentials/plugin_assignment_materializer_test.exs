defmodule ServiceRadar.Credentials.PluginAssignmentMaterializerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Plugins.PluginInputs

  defmodule FakeReconciler do
    @moduledoc false

    def reconcile(policy, input_defs, opts) do
      send(opts[:test_pid], {:reconcile, policy, input_defs, opts})

      {:ok,
       %{
         resolved_inputs: 1,
         desired_assignments: 2,
         upserted: 1,
         unchanged: 1,
         disabled: 0
       }}
    end
  end

  test "reconcile_rules builds Proxmox plugin policies from credential rules" do
    updated_at = ~U[2026-05-06 19:30:00Z]

    rules = [
      %{
        id: "rule-1",
        secret_id: "018f3f56-1111-7222-8333-123456789abc",
        purpose: :inventory_enrichment,
        target_query: "in:devices metadata.proxmox_candidate:true",
        tls_policy: :verify,
        updated_at: updated_at,
        metadata: %{
          "include_guests" => false,
          "timeout_ms" => 45_000,
          "interval_seconds" => 600,
          "timeout_seconds" => 45,
          "chunk_size" => 25,
          "auto_discovery_enabled" => true
        }
      }
    ]

    package = %{id: "pkg-proxmox"}

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", package,
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               expected_partition_id: "farm01",
               test_pid: self()
             )

    assert summary == %{
             rules: 1,
             resolved_inputs: 1,
             desired_assignments: 2,
             upserted: 1,
             unchanged: 1,
             disabled: 0,
             skips: %{}
           }

    assert_receive {:reconcile, policy, input_defs, opts}

    assert policy.policy_id == "network-credential-rule:rule-1"
    assert policy.policy_version == DateTime.to_unix(updated_at, :second)
    assert policy.plugin_package_id == "pkg-proxmox"
    assert policy.interval_seconds == 600
    assert policy.timeout_seconds == 45
    assert opts[:chunk_size] == 25
    assert opts[:target_agent_uid] == "agent-a"
    assert opts[:expected_partition_id] == "farm01"

    assert input_defs == [
             %{
               name: "targets",
               entity: "devices",
               query: "in:devices metadata.proxmox_candidate:true"
             }
           ]

    assert %{
             "credential_broker" => %{
               "credential_secret_ref" => ref,
               "credential_rule_id" => "rule-1",
               "grant_type" => "proxmox_api_token",
               "inject" => %{
                 "type" => "http_header",
                 "name" => "Authorization",
                 "scheme" => "PVEAPIToken"
               }
             },
             "api_token_secret_ref" => ref,
             "credential_rule_id" => "rule-1",
             "include_guests" => false,
             "timeout_ms" => 45_000,
             "auto_discovery_enabled" => true
           } = policy.params_template

    assert ref == "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"
    broker = policy.params_template["credential_broker"]
    assert is_binary(broker["grant_id"])
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(broker["expires_at"])
    refute Map.has_key?(policy.params_template, "credential_secret_id")
  end

  test "reconcile_rules leaves auto-discovery disabled unless explicitly enabled" do
    rules = [
      credential_rule(%{
        id: "srql-only",
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-1111-7222-8333-123456789abc"
      })
    ]

    assert {:ok, _summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", %{id: "pkg-proxmox"},
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert_receive {:reconcile, policy, input_defs, _opts}
    assert hd(input_defs).query == "in:devices metadata.proxmox_candidate:true"
    assert policy.params_template["auto_discovery_enabled"] == false
  end

  test "reconcile_rules reports insecure Proxmox policy as a stable skip before grant issuance" do
    rules = [
      credential_rule(%{
        id: "insecure-proxmox",
        tls_policy: :skip_verify
      })
    ]

    grant_issuer = fn _attrs ->
      send(self(), :grant_issued)
      {:error, :unexpected_grant}
    end

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", %{id: "pkg-proxmox"},
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               grant_issuer: grant_issuer,
               test_pid: self()
             )

    assert summary == %{
             rules: 1,
             resolved_inputs: 0,
             desired_assignments: 0,
             upserted: 0,
             unchanged: 0,
             disabled: 0,
             skips: %{proxmox_tls_verification_required: 1}
           }

    refute_receive :grant_issued
    refute_receive {:reconcile, _policy, _input_defs, _opts}
  end

  test "reconcile_rules builds Proxmox console plugin policies from console credential rules" do
    rules = [
      credential_rule(%{
        id: "console-rule",
        purpose: :console_access,
        auth_method: :ssh_private_key,
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-5555-7666-8777-123456789abc",
        ssh_host_key_policy: :trust_on_first_use,
        metadata: %{
          "timeout_ms" => 20_000,
          "interval_seconds" => 900,
          "timeout_seconds" => 20,
          "chunk_size" => 10
        }
      })
    ]

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(
               rules,
               "agent-a",
               %{id: "pkg-proxmox-console"},
               purpose: :console_access,
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert summary.rules == 1
    assert_receive {:reconcile, policy, input_defs, opts}

    assert policy.policy_id == "network-credential-rule:console-rule:console_access"
    assert policy.plugin_package_id == "pkg-proxmox-console"
    assert policy.interval_seconds == 900
    assert policy.timeout_seconds == 20
    assert opts[:chunk_size] == 10
    assert hd(input_defs).query == "in:devices metadata.proxmox_candidate:true"

    assert %{
             "credential_broker" => %{
               "credential_secret_ref" => ref,
               "credential_rule_id" => "console-rule",
               "grant_type" => "proxmox_console",
               "auth_method" => "ssh_private_key"
             },
             "credential_secret" => ref,
             "credential_rule_id" => "console-rule",
             "ssh_host_key_policy" => "trust_on_first_use",
             "timeout_ms" => 20_000
           } = policy.params_template

    assert ref == "credentialref:network-credential-secret:018f3f56-5555-7666-8777-123456789abc"
    broker = policy.params_template["credential_broker"]
    assert is_binary(broker["grant_id"])
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(broker["expires_at"])
    refute Map.has_key?(policy.params_template, "include_guests")
    refute Map.has_key?(policy.params_template, "auto_discovery_enabled")
  end

  test "reconcile_rules does not build console policies from inventory-only API-token rules" do
    rules = [
      credential_rule(%{
        id: "shared-proxmox-api-rule",
        purpose: :inventory_enrichment,
        auth_method: :proxmox_api_token,
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "secret-proxmox-api-shared"
      })
    ]

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(
               rules,
               "agent-a",
               %{id: "pkg-proxmox-console"},
               purpose: :console_access,
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert summary.rules == 0
    refute_receive {:reconcile, _policy, _input_defs, _opts}
  end

  test "materialized policy output is compatible with plugin inputs planner payloads" do
    rules = [
      %{
        "id" => "rule-2",
        "secret_id" => "018f3f56-2222-7333-8444-123456789abc",
        "target_query" => "in:devices vendor:Proxmox",
        "metadata" => %{}
      }
    ]

    package = %{"id" => "pkg-proxmox"}

    assert {:ok, _summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", package,
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert_receive {:reconcile, policy, _input_defs, _opts}

    payload = %{
      "schema" => PluginInputs.schema_id(),
      "policy_id" => policy.policy_id,
      "policy_version" => policy.policy_version,
      "agent_id" => "agent-a",
      "generated_at" => "2026-05-06T19:35:00Z",
      "template" => policy.params_template,
      "inputs" => [
        %{
          "name" => "targets",
          "entity" => "devices",
          "query" => "in:devices vendor:Proxmox",
          "chunk_index" => 0,
          "chunk_total" => 1,
          "chunk_hash" => String.duplicate("a", 64),
          "items" => [%{"uid" => "sr:device:1", "ip" => "192.0.2.10"}]
        }
      ]
    }

    assert :ok = PluginInputs.validate(payload)
  end

  test "reconcile_rules applies priority, disabled, and agent scope selection before materializing" do
    rules = [
      credential_rule(%{
        id: "winner",
        priority: 10,
        scope_type: :agent,
        scope_value: "agent-a",
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-1111-7222-8333-123456789abc"
      }),
      credential_rule(%{
        id: "lower-priority",
        priority: 50,
        scope_type: :agent,
        scope_value: "agent-a",
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-2222-7333-8444-123456789abc"
      }),
      credential_rule(%{
        id: "disabled",
        enabled: false,
        priority: 1,
        scope_type: :agent,
        scope_value: "agent-a",
        target_query: "in:devices vendor:disabled",
        secret_id: "018f3f56-3333-7444-8555-123456789abc"
      }),
      credential_rule(%{
        id: "wrong-agent",
        priority: 1,
        scope_type: :agent,
        scope_value: "agent-b",
        target_query: "in:devices vendor:wrong-agent",
        secret_id: "018f3f56-4444-7555-8666-123456789abc"
      })
    ]

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", %{id: "pkg-proxmox"},
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert summary.rules == 1
    assert_receive {:reconcile, policy, input_defs, _opts}
    assert policy.policy_id == "network-credential-rule:winner"
    assert hd(input_defs).query == "in:devices metadata.proxmox_candidate:true"

    refute_receive {:reconcile, %{policy_id: "network-credential-rule:lower-priority"}, _, _}
    refute_receive {:reconcile, %{policy_id: "network-credential-rule:disabled"}, _, _}
    refute_receive {:reconcile, %{policy_id: "network-credential-rule:wrong-agent"}, _, _}
  end

  test "reconcile_rules rejects equal-priority credential conflicts for the same target query" do
    rules = [
      credential_rule(%{
        id: "one",
        priority: 10,
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-1111-7222-8333-123456789abc"
      }),
      credential_rule(%{
        id: "two",
        priority: 10,
        target_query: "in:devices metadata.proxmox_candidate:true",
        secret_id: "018f3f56-2222-7333-8444-123456789abc"
      })
    ]

    assert {:error,
            {:equal_priority_credential_rule_conflict,
             "in:devices metadata.proxmox_candidate:true", 10}} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", %{id: "pkg-proxmox"},
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    refute_receive {:reconcile, _, _, _}
  end

  defp credential_rule(attrs) do
    Map.merge(
      %{
        id: "rule",
        secret_id: "018f3f56-1111-7222-8333-123456789abc",
        enabled: true,
        priority: 100,
        purpose: :inventory_enrichment,
        target_query: "in:devices",
        tls_policy: :verify,
        scope_type: :agent,
        scope_value: "agent-a",
        metadata: %{}
      },
      attrs
    )
  end
end
