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
        target_query: "in:devices protocol:proxmox-api",
        tls_policy: :skip_verify,
        updated_at: updated_at,
        metadata: %{
          "include_guests" => false,
          "timeout_ms" => 45_000,
          "interval_seconds" => 600,
          "timeout_seconds" => 45,
          "chunk_size" => 25
        }
      }
    ]

    package = %{id: "pkg-proxmox"}

    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_rules(rules, "agent-a", package,
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               test_pid: self()
             )

    assert summary == %{
             rules: 1,
             resolved_inputs: 1,
             desired_assignments: 2,
             upserted: 1,
             unchanged: 1,
             disabled: 0
           }

    assert_receive {:reconcile, policy, input_defs, opts}

    assert policy.policy_id == "network-credential-rule:rule-1"
    assert policy.policy_version == DateTime.to_unix(updated_at, :second)
    assert policy.plugin_package_id == "pkg-proxmox"
    assert policy.interval_seconds == 600
    assert policy.timeout_seconds == 45
    assert opts[:chunk_size] == 25

    assert input_defs == [
             %{name: "targets", entity: "devices", query: "in:devices protocol:proxmox-api"}
           ]

    assert %{
             "api_token_secret_ref" => ref,
             "credential_rule_id" => "rule-1",
             "credential_secret_id" => "018f3f56-1111-7222-8333-123456789abc",
             "include_guests" => false,
             "insecure_skip_verify" => true,
             "timeout_ms" => 45_000
           } = policy.params_template

    assert ref == "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"
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
end
