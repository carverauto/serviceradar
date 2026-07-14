defmodule ServiceRadar.Inventory.ProxmoxSourceScopeResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.ProxmoxSourceScopeResolver

  @assignment_id "11111111-1111-4111-8111-111111111111"
  @rule_id "22222222-2222-4222-8222-222222222222"
  @integration_id "33333333-3333-4333-8333-333333333333"
  @controller_id "44444444-4444-4444-8444-444444444444"
  @agent_id "edge-farm01"
  @partition_id "farm01"

  test "resolves immutable scope through the authenticated policy assignment" do
    assert {:ok, scope} = resolve()

    assert scope == %{
             integration_id: @integration_id,
             controller_id: @controller_id,
             partition_id: @partition_id,
             assignment_id: @assignment_id,
             credential_rule_id: @rule_id
           }
  end

  test "resolves the same scope directly from a loaded assignment for config generation" do
    assert {:ok, scope} =
             ProxmoxSourceScopeResolver.resolve_assignment(assignment_fixture(),
               actor: %{},
               agent_id: @agent_id,
               partition_id: @partition_id,
               rule_loader: fn @rule_id, _actor -> {:ok, rule_fixture()} end
             )

    assert scope.integration_id == @integration_id
    assert scope.controller_id == @controller_id
    assert scope.assignment_id == @assignment_id
  end

  test "inventory and console assignments for one rule resolve the same source scope" do
    rule =
      Map.put(rule_fixture(), :metadata, %{
        "purposes" => ["inventory_enrichment", "console_access"]
      })

    loader = fn @rule_id, _actor -> {:ok, rule} end

    assert {:ok, inventory_scope} =
             ProxmoxSourceScopeResolver.resolve_assignment(assignment_fixture(),
               actor: %{},
               agent_id: @agent_id,
               partition_id: @partition_id,
               rule_loader: loader
             )

    assert {:ok, console_scope} =
             ProxmoxSourceScopeResolver.resolve_assignment(console_assignment_fixture(),
               actor: %{},
               agent_id: @agent_id,
               partition_id: @partition_id,
               rule_loader: loader
             )

    assert Map.take(inventory_scope, [:integration_id, :controller_id, :credential_rule_id]) ==
             Map.take(console_scope, [:integration_id, :controller_id, :credential_rule_id])
  end

  test "console source scope accepts only verified API-token or SSH-key transports" do
    base_rule =
      Map.put(rule_fixture(), :metadata, %{
        "purposes" => ["inventory_enrichment", "console_access"]
      })

    for rule <- [
          base_rule,
          Map.merge(base_rule, %{
            auth_method: :ssh_private_key,
            ssh_host_key_policy: :trust_on_first_use
          })
        ] do
      assert {:ok, _scope} =
               ProxmoxSourceScopeResolver.resolve_assignment(console_assignment_fixture(),
                 actor: %{},
                 agent_id: @agent_id,
                 partition_id: @partition_id,
                 rule_loader: fn @rule_id, _actor -> {:ok, rule} end
               )
    end

    rejected = [
      {Map.put(base_rule, :tls_policy, :skip_verify), :proxmox_tls_verification_required},
      {Map.merge(base_rule, %{
         auth_method: :ssh_private_key,
         ssh_host_key_policy: :skip_verify
       }), :proxmox_ssh_host_key_verification_required},
      {Map.put(base_rule, :auth_method, :certificate), :unsupported_proxmox_console_auth_method}
    ]

    for {rule, expected} <- rejected do
      assert {:error, ^expected} =
               ProxmoxSourceScopeResolver.resolve_assignment(console_assignment_fixture(),
                 actor: %{},
                 agent_id: @agent_id,
                 partition_id: @partition_id,
                 rule_loader: fn @rule_id, _actor -> {:ok, rule} end
               )
    end
  end

  test "inventory source scope requires a verified Proxmox API token" do
    for {change, expected} <- [
          {%{tls_policy: :skip_verify}, :proxmox_tls_verification_required},
          {%{auth_method: :ssh_private_key}, :unsupported_proxmox_inventory_auth_method}
        ] do
      rule = Map.merge(rule_fixture(), change)

      assert {:error, ^expected} = resolve(rule: rule)
    end
  end

  test "accepts a matching assignment id stamped into both status and payload labels" do
    assert {:ok, _scope} =
             resolve(
               payload: %{"labels" => %{"assignment_id" => @assignment_id}},
               status: Map.put(status_fixture(), "labels", %{"assignment_id" => @assignment_id})
             )
  end

  test "rejects missing or conflicting authenticated assignment labels" do
    assert {:error, :missing_trusted_assignment_id} =
             resolve(payload: %{}, status: %{"agent_id" => @agent_id})

    assert {:error, :conflicting_trusted_assignment_ids} =
             resolve(
               payload: %{"labels" => %{"assignment_id" => Ecto.UUID.generate()}},
               status: Map.put(status_fixture(), "labels", %{"assignment_id" => @assignment_id})
             )
  end

  test "rejects disabled, manual, wrong-agent, and wrong-plugin assignments" do
    cases = [
      {%{enabled: false}, :plugin_assignment_disabled},
      {%{source: :manual}, :plugin_assignment_not_policy_managed},
      {%{agent_uid: "edge-tonka01"}, :plugin_assignment_agent_mismatch},
      {%{partition_id: "tonka01"}, :plugin_assignment_partition_mismatch},
      {%{plugin_id: "proxmox-console"}, :plugin_assignment_plugin_mismatch}
    ]

    for {change, expected} <- cases do
      assignment = Map.merge(assignment_fixture(), change)
      assert {:error, ^expected} = resolve(assignment: assignment)
    end
  end

  test "does not accept a result-owned partition as a substitute for transport evidence" do
    assert {:error, :missing_authenticated_partition_id} =
             resolve(
               payload: Map.put(payload_fixture(), "partition_id", @partition_id),
               status: Map.delete(status_fixture(), "partition")
             )

    assert {:error, :plugin_assignment_partition_mismatch} =
             resolve(status: Map.put(status_fixture(), "partition", "tonka01"))
  end

  test "rejects a wrong or unapproved package and drifted assignment policy params" do
    wrong_package =
      put_in(assignment_fixture(), [:plugin_package, :plugin_id], "proxmox-console")

    assert {:error, :plugin_assignment_package_mismatch} =
             resolve(assignment: wrong_package)

    unapproved = put_in(assignment_fixture(), [:plugin_package, :status], :staged)

    assert {:error, :plugin_assignment_package_not_approved} =
             resolve(assignment: unapproved)

    drifted = put_in(assignment_fixture(), [:params, "policy_id"], "another-policy")

    assert {:error, :plugin_assignment_policy_mismatch} =
             resolve(assignment: drifted)
  end

  test "rejects malformed and non-inventory policy ids" do
    assert {:error, :invalid_proxmox_inventory_policy_id} =
             resolve(assignment: Map.put(assignment_fixture(), :policy_id, "manual"))

    console_policy = "network-credential-rule:#{@rule_id}:console_access"

    assignment =
      assignment_fixture()
      |> Map.put(:policy_id, console_policy)
      |> put_in([:params, "policy_id"], console_policy)

    assert {:error, :invalid_proxmox_inventory_policy_id} = resolve(assignment: assignment)
  end

  test "rejects disabled, wrong-provider, and wrong-purpose rules" do
    cases = [
      {%{enabled: false}, :credential_rule_disabled},
      {%{provider: "vsphere"}, :credential_rule_provider_mismatch},
      {%{purpose: :console_access}, :credential_rule_purpose_mismatch}
    ]

    for {change, expected} <- cases do
      rule = Map.merge(rule_fixture(), change)
      assert {:error, ^expected} = resolve(rule: rule)
    end
  end

  test "rejects invalid source UUIDs instead of minting provenance" do
    assert {:error, :invalid_uuid} =
             resolve(rule: Map.put(rule_fixture(), :integration_id, "farm01"))

    assert {:error, :invalid_uuid} =
             resolve(rule: Map.put(rule_fixture(), :controller_id, "pve01"))
  end

  test "rejects a reported plugin mismatch before loading assignment state" do
    assert {:error, :proxmox_inventory_plugin_mismatch} =
             resolve(status: Map.put(status_fixture(), "plugin_id", "proxmox-console"))

    assert {:error, :proxmox_inventory_plugin_mismatch} =
             resolve(
               payload: %{"labels" => %{"assignment_id" => @assignment_id}},
               status: Map.delete(status_fixture(), "plugin_id")
             )
  end

  test "accepts the runtime-stamped payload plugin when status has no duplicate field" do
    assert {:ok, _scope} = resolve(status: Map.delete(status_fixture(), "plugin_id"))
  end

  test "requires every trusted v3 delivery capability" do
    required = [
      "plugin-host-authority:v1",
      "proxmox-semantic-connector:v1",
      "proxmox-identity:v3"
    ]

    for missing <- required do
      status =
        Map.put(
          status_fixture(),
          "delivery_capabilities",
          List.delete(required, missing)
        )

      assert {:error, {:missing_proxmox_identity_delivery_capabilities, [^missing]}} =
               resolve(status: status)
    end

    assert {:error, {:missing_proxmox_identity_delivery_capabilities, missing}} =
             resolve(
               status:
                 Map.put(status_fixture(), "delivery_capabilities", [
                   "plugin-host-authority:v1",
                   "proxmox-semantic-connector:v1",
                   "proxmox-identity:v2"
                 ])
             )

    assert missing == ["proxmox-identity:v3"]
  end

  defp resolve(overrides \\ []) do
    assignment = Keyword.get(overrides, :assignment, assignment_fixture())
    rule = Keyword.get(overrides, :rule, rule_fixture())
    payload = Keyword.get(overrides, :payload, payload_fixture())
    status = Keyword.get(overrides, :status, status_fixture())

    ProxmoxSourceScopeResolver.resolve(payload, status,
      actor: %{},
      assignment_loader: fn @assignment_id, _actor -> {:ok, assignment} end,
      rule_loader: fn @rule_id, _actor -> {:ok, rule} end
    )
  end

  defp payload_fixture do
    %{
      "labels" => %{
        "assignment_id" => @assignment_id,
        "plugin_id" => "proxmox-inventory"
      }
    }
  end

  defp status_fixture do
    %{
      "agent_id" => @agent_id,
      "partition" => @partition_id,
      "plugin_id" => "proxmox-inventory",
      "delivery_capabilities" => [
        "plugin-host-authority:v1",
        "proxmox-semantic-connector:v1",
        "proxmox-identity:v3"
      ]
    }
  end

  defp assignment_fixture do
    policy_id = "network-credential-rule:#{@rule_id}"

    %{
      id: @assignment_id,
      enabled: true,
      source: :policy,
      agent_uid: @agent_id,
      partition_id: @partition_id,
      plugin_id: "proxmox-inventory",
      policy_id: policy_id,
      params: %{"policy_id" => policy_id},
      plugin_package: %{
        id: Ecto.UUID.generate(),
        plugin_id: "proxmox-inventory",
        status: :approved
      }
    }
  end

  defp console_assignment_fixture do
    policy_id = "network-credential-rule:#{@rule_id}:console_access"

    assignment_fixture()
    |> Map.put(:id, "55555555-5555-4555-8555-555555555555")
    |> Map.put(:plugin_id, "proxmox-console")
    |> Map.put(:policy_id, policy_id)
    |> Map.put(:params, %{"policy_id" => policy_id})
    |> put_in([:plugin_package, :plugin_id], "proxmox-console")
  end

  defp rule_fixture do
    %{
      id: @rule_id,
      enabled: true,
      provider: "proxmox",
      purpose: :inventory_enrichment,
      auth_method: :proxmox_api_token,
      tls_policy: :verify,
      ssh_host_key_policy: :known_hosts,
      metadata: %{},
      integration_id: @integration_id,
      controller_id: @controller_id
    }
  end
end
