defmodule ServiceRadar.Credentials.PluginAssignmentMaterializerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

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

  test "the shipped OTX package provisions one credential-backed feed assignment" do
    root = Path.expand("../../../../../go/cmd/wasm-plugins/alienvault-otx", __DIR__)
    assert {:ok, manifest} = root |> Path.join("plugin.yaml") |> File.read!() |> Manifest.parse_yaml_map()
    schema = root |> Path.join("config.schema.json") |> File.read!() |> Jason.decode!()

    assert {:ok, catalog} = IntegrationCatalog.from_packages([
      %{id: "pkg-otx", plugin_id: manifest["id"], version: manifest["version"],
        manifest: manifest, config_schema: schema}
    ])
    assert [profile] = catalog.credential_profiles

    rule = credential_rule(%{
      provider: "alienvault-otx", purpose: "threat_intel_sync",
      target_query: profile["rule_defaults"]["target_query"],
      metadata: %{"interval_seconds" => 86_400, "timeout_seconds" => 600}
    })

    assert {:ok, summary} = materialize([rule], profile: profile, purpose: "threat_intel_sync")
    assert summary.rules == 1
    assert_receive {:reconcile, policy, input_defs, opts}
    assert opts[:single_assignment]
    assert opts[:target_agent_uid] == "agent-a"
    assert policy.interval_seconds == 86_400
    assert policy.timeout_seconds == 600
    assert input_defs == [%{name: "targets", entity: "devices", query: rule.target_query}]
    assert policy.params_template["api_key_secret_ref"] == SecretRefs.network_credential_ref(rule.secret_id)
    assert policy.params_template["credential_broker"]["grant_id"] == "grant-1"
    assert get_in(policy.params_template, ["credential_broker", "consumer", "id"]) == manifest["id"]
    assert policy.params_template["base_url"] == "https://otx.alienvault.com"
    assert get_in(policy.params_template, ["credential_broker", "allow", "hosts"]) == ["otx.alienvault.com"]
    assert get_in(policy.params_template, ["credential_broker", "target", "agent_id"]) == "agent-a"
    assert :ok = ConfigSchema.validate_params(schema, policy.params_template)

    # The same global feed must not be provisioned once per agent in a gateway.
    assert {:ok, skipped} = materialize([%{rule | scope_type: :gateway, scope_value: "gateway-1"}],
      profile: profile, purpose: "threat_intel_sync")
    assert skipped.skips == %{single_target_rule_not_agent_scoped: 1}
    refute_receive {:reconcile, _policy, _inputs, _opts}
  end

  test "materializes an arbitrary package-declared provider without a core registry" do
    updated_at = ~U[2026-05-06 19:30:00Z]

    rule =
      credential_rule(%{
        updated_at: updated_at,
        metadata: %{
          "timeout_ms" => 45_000,
          "interval_seconds" => 600,
          "timeout_seconds" => 45,
          "chunk_size" => 25,
          "credential_broker_ttl_seconds" => 45
        }
      })

    assert {:ok, summary} = materialize([rule])

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
    assert policy.policy_id == "network-credential-rule:rule-1:device_inventory"
    assert policy.policy_version == DateTime.to_unix(updated_at, :second)
    assert policy.plugin_package_id == "pkg-example"
    assert policy.interval_seconds == 600
    assert policy.timeout_seconds == 45
    assert opts[:chunk_size] == 25
    assert opts[:target_agent_uid] == "agent-a"
    assert opts[:single_assignment] == false
    # Stale-row retraction is per agent: a policy id is shared by every agent a
    # rule covers, so a wider scope would disable other agents' assignments.
    assert opts[:agent_scope] == ["agent-a"]

    assert input_defs == [
             %{name: "targets", entity: "devices", query: "in:devices vendor:Example"}
           ]

    assert %{
             "credential_broker" => %{
               "credential_secret_ref" => ref,
               "credential_rule_id" => "rule-1",
               "grant_type" => "example_api",
               "consumer" => %{
                 "kind" => "plugin",
                 "id" => "example-network-inventory",
                 "purpose" => "device_inventory"
               },
               "target" => %{"agent_id" => "agent-a"},
               "resolution_location" => "agent",
               "ttl_seconds" => 45,
               "inject" => %{
                 "type" => "http_header",
                 "name" => "Authorization",
                 "scheme" => "Bearer"
               },
               "allow" => %{
                 "methods" => ["GET"],
                 "paths" => ["/api/devices"],
                 "ports" => [443]
               }
             },
             "credential_secret_ref" => ref,
             "credential_rule_id" => "rule-1",
             "timeout_ms" => 45_000
           } = policy.params_template

    assert ref == "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    # The template carries scope only: the grant is issued when the credential
    # is delivered or resolved, never by the reconcile.
    refute Map.has_key?(policy.params_template["credential_broker"], "grant_id")
    refute Map.has_key?(policy.params_template["credential_broker"], "expires_at")
  end

  test "renders public credential metadata only when the manifest requests it" do
    rule =
      credential_rule(%{
        auth_method: "username_password",
        purpose: "configuration_read",
        metadata: %{"purposes" => ["configuration_read"]}
      })

    resolver = fn _secret_id, _actor -> {:ok, "operator"} end

    assert {:ok, _summary} =
             materialize([rule], purpose: "configuration_read", username_resolver: resolver)

    assert_receive {:reconcile, policy, _input_defs, _opts}
    assert policy.params_template["username"] == "operator"
    assert policy.params_template["password_secret_ref"] =~ "credentialref:"
    assert policy.params_template["credential_broker"]["resolution_location"] == "control_plane"
  end

  test "manifest transport constraints fail closed before materialization" do
    rule = credential_rule(%{tls_policy: :skip_verify})

    assert {:ok, summary} = materialize([rule])
    assert summary.rules == 1
    assert summary.skips == %{credential_tls_policy_not_allowed: 1}
    refute_receive {:reconcile, _policy, _inputs, _opts}
  end

  test "priority and agent scope select one authoritative rule" do
    rules = [
      credential_rule(%{id: "winner", priority: 10}),
      credential_rule(%{id: "lower", priority: 50}),
      credential_rule(%{
        id: "disabled",
        enabled: false,
        target_query: "in:devices disabled:true"
      }),
      credential_rule(%{
        id: "other-agent",
        scope_value: "agent-b",
        target_query: "in:devices other:true"
      })
    ]

    assert {:ok, %{rules: 1}} = materialize(rules)

    assert_receive {:reconcile, %{policy_id: "network-credential-rule:winner:device_inventory"},
                    _, _}

    refute_receive {:reconcile, _, _, _}
  end

  test "equal-priority rules for the same query fail closed" do
    rules = [credential_rule(%{id: "one"}), credential_rule(%{id: "two"})]

    assert {:error, {:equal_priority_credential_rule_conflict, "in:devices vendor:Example", 100}} =
             materialize(rules)

    refute_receive {:reconcile, _, _, _}
  end

  test "a single-cardinality consumer is delivered as one assignment regardless of chunk_size" do
    # The manifest, not the rule, decides this: a consumer whose run covers a
    # whole instance would otherwise run once per chunk against the same
    # endpoint, and rule metadata must not be able to reintroduce that.
    rule = credential_rule(%{metadata: %{"chunk_size" => 25}})

    assert {:ok, _summary} = materialize([rule], profile: single_cardinality_profile())

    assert_receive {:reconcile, _policy, _input_defs, opts}
    assert opts[:single_assignment] == true
    assert opts[:chunk_size] == 25
  end

  test "a single-cardinality rule is delivered only to the agent its scope names" do
    # `single` means one run covers the whole instance, and this reconcile runs
    # once per agent. A gateway scope is in scope for every agent under the
    # gateway, so without the owner check the same instance is synced once per
    # agent -- each run emitting another complete snapshot under one
    # source_instance. Chunk collapsing does not help: those are separate
    # (rule, agent) pairs, and per-agent retraction leaves every one enabled.
    rule = credential_rule(%{scope_type: :gateway, scope_value: "gateway-1"})

    assert {:ok, summary} = materialize([rule], profile: single_cardinality_profile())

    assert summary.skips == %{single_target_rule_not_agent_scoped: 1}
    assert summary.desired_assignments == 0
    refute_receive {:reconcile, _policy, _input_defs, _opts}
  end

  test "a per_target rule still fans out across the agents its scope covers" do
    rule = credential_rule(%{scope_type: :gateway, scope_value: "gateway-1"})

    assert {:ok, summary} = materialize([rule])

    assert summary.skips == %{}
    assert_receive {:reconcile, _policy, _input_defs, opts}
    assert opts[:target_agent_uid] == "agent-a"
  end

  # Enters through reconcile_provider_for_agent/4, the function the reconcile
  # worker reaches through reconcile_all_for_agent/2. Injected rules are
  # filtered by provider and purpose exactly as the loaded path is.
  defp materialize(rules, opts \\ []) do
    {profile, opts} = Keyword.pop(opts, :profile, profile())
    {purpose, opts} = Keyword.pop(opts, :purpose, "device_inventory")

    PluginAssignmentMaterializer.reconcile_provider_for_agent(
      profile,
      "agent-a",
      purpose,
      Keyword.merge(
        [
          rules: rules,
          plugin_package: %{id: "pkg-example"},
          reconciler: FakeReconciler,
          test_pid: self()
        ],
        opts
      )
    )
  end

  defp credential_rule(attrs) do
    Map.merge(
      %{
        id: "rule-1",
        secret_id: "018f3f56-1111-7222-8333-123456789abc",
        enabled: true,
        priority: 100,
        provider: "example-network",
        auth_method: "api_token",
        purpose: "device_inventory",
        target_query: "in:devices vendor:Example",
        tls_policy: :verify,
        ssh_host_key_policy: :known_hosts,
        scope_type: :agent,
        scope_value: "agent-a",
        metadata: %{}
      },
      attrs
    )
  end

  defp profile, do: CredentialIntegrationFixtures.target_policy_profile()

  defp single_cardinality_profile do
    profile = profile()

    consumers =
      Enum.map(
        profile["provisioning"]["consumers"],
        &Map.put(&1, "target_cardinality", "single")
      )

    put_in(profile, ["provisioning", "consumers"], consumers)
  end
end
