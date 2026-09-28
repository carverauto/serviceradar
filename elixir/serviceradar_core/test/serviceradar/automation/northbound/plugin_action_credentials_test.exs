defmodule ServiceRadar.Automation.Northbound.PluginActionCredentialsTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.Catalog
  alias ServiceRadar.Automation.Northbound.CredentialGrants
  alias ServiceRadar.Automation.Northbound.Dispatcher
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Automation.Northbound.PluginPackageContext
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  @system_actor SystemActor.system(:northbound_plugin_action_credentials_test)
  @schedule_id "example-sat.inventory.refresh"
  @schedule_ref "example_account"
  @partition_id "default"

  @source_requirement %{
    "credential_source" => "assignment_schedule",
    "requirement" => @schedule_ref,
    "required" => true,
    "grant_type" => "http_api_callout",
    "purpose" => "management",
    "ttl_seconds" => 120,
    "allow" => %{
      "methods" => ["POST"],
      "hosts" => ["api.example.com"],
      "paths" => ["/v1/terminals/reboot"],
      "ports" => [443]
    },
    "inject" => %{"type" => "http_header", "name" => "Authorization", "scheme" => "Bearer"}
  }

  @destination_requirement %{
    "credential_source" => "package_rule",
    "rule_input" => "destination_rule_id",
    "required" => true,
    "purpose" => "management",
    "allow" => %{"methods" => ["POST"], "hosts" => ["api.example.com"]}
  }

  defmodule CapturingCommandBus do
    @moduledoc false

    def dispatch(agent_uid, command_type, payload, opts) do
      send(self(), {:dispatched, agent_uid, command_type, payload, opts[:transmit_payload]})
      {:ok, %{id: Ecto.UUID.generate()}}
    end
  end

  defmodule FakeGrantIssuer do
    @moduledoc false

    def issue(attrs, _opts) do
      send(self(), {:grant_attrs, attrs})

      attrs =
        attrs
        |> CredentialBrokerGrant.issue_attrs()
        |> Map.put(:id, Ecto.UUID.generate())

      {:ok, CredentialBrokerGrant.to_payload(attrs)}
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  describe "credential_source: assignment_schedule" do
    test "dispatch mints the grant from the secret bound to the assignment's schedule" do
      %{package: package, rules: [rule]} = provisioned_package!("dispatch", 1)

      {:ok, descriptor} =
        plugin_descriptor(package, %{"source_account" => @source_requirement})

      {:ok, invocation} = create_event_invocation(descriptor)

      assert {:ok, _invocation} =
               Dispatcher.dispatch_invocation(invocation,
                 command_bus: CapturingCommandBus,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )

      assert_received {:grant_attrs, attrs}
      assert attrs.secret_ref == secret_ref(rule.secret_id)
      assert attrs.credential_rule_id == rule.id
      assert attrs.allowed_methods == ["POST"]
      assert attrs.allowed_hosts == ["api.example.com"]
      assert attrs.allowed_paths == ["/v1/terminals/reboot"]
      assert attrs.allowed_ports == [443]
      assert attrs.ttl_seconds == 120
      assert attrs.inject["name"] == "Authorization"
      assert attrs.metadata["credential_source"] == "assignment_schedule"

      assert_received {:dispatched, _agent_uid, "plugin.run_action", _stored, transmitted}
      assert [%{"credential_secret_ref" => ref}] = transmitted["credential_brokers"]
      assert ref == secret_ref(rule.secret_id)
    end

    test "only the assignment the schedule is bound to receives its secret" do
      %{package: package, rules: [first, second], assignments: [first_assignment, bound]} =
        provisioned_package!("bound", 2)

      invocation =
        in_memory_invocation(package, %{"source_account" => @source_requirement}, %{})

      assert {:ok, _prepared} =
               CredentialGrants.prepare_launch(invocation, bound,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )

      assert_received {:grant_attrs, attrs}
      assert attrs.secret_ref == secret_ref(second.secret_id)
      refute attrs.secret_ref == secret_ref(first.secret_id)

      assert {:error, {:no_bound_schedule_credential, "source_account", @schedule_ref}} =
               CredentialGrants.prepare_launch(invocation, first_assignment,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )
    end

    test "an assignment with no bound schedule fails before anything is dispatched" do
      unique = System.unique_integer([:positive])

      package =
        approved_package!("example-sat-unbound-#{unique}", "example-sat-unbound-#{unique}")

      agent_uid = "northbound-unbound-agent-#{unique}"
      register_control_session!(agent_uid)

      {:ok, _assignment} =
        PluginAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{agent_uid: agent_uid, plugin_package_id: package.id, enabled: true},
          actor: @system_actor
        )
        |> Ash.create(actor: @system_actor, return_notifications?: true)
        |> case do
          {:ok, assignment, _notifications} -> {:ok, assignment}
          other -> other
        end

      {:ok, descriptor} =
        plugin_descriptor(package, %{"source_account" => @source_requirement})

      {:ok, invocation} = create_event_invocation(descriptor)

      assert {:error, {:no_bound_schedule_credential, "source_account", @schedule_ref}} =
               Dispatcher.dispatch_invocation(invocation,
                 command_bus: CapturingCommandBus,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )

      refute_received {:grant_attrs, _attrs}
      refute_received {:dispatched, _agent_uid, _command_type, _stored, _transmitted}

      assert {:ok, failed} = ActionInvocation.get_by_id(invocation.id, actor: @system_actor)
      assert failed.state == :failed
    end
  end

  describe "credential_source: package_rule" do
    setup do
      unique = System.unique_integer([:positive])
      provider = "example-sat-move-#{unique}"
      package = approved_package!("example-sat-move-#{unique}", provider)

      disabled_rule = rule!(provider, "northbound-move-disabled-#{unique}")
      first_rule = rule!(provider, "northbound-move-first-#{unique}")
      second_rule = rule!(provider, "northbound-move-second-#{unique}")

      # Reconciled in this order the package schedule ends up bound to the
      # second rule's assignment.
      :ok = provision!(package, [disabled_rule, first_rule, second_rule])
      bound = assignment_for!(second_rule)

      # Disabled after provisioning and before the next reconcile, so its
      # assignment is still enabled and only the rule state rejects it.
      {:ok, disabled_rule} =
        disabled_rule
        |> Ash.Changeset.for_update(:disable, %{}, actor: @system_actor)
        |> Ash.update(actor: @system_actor)

      assert assignment_for!(disabled_rule).enabled

      # Same provider, enabled, but never provisioned for the package.
      unprovisioned_rule = rule!(provider, "northbound-move-unprovisioned-#{unique}")

      # A rule provisioned for a different package and provider.
      %{rules: [foreign_rule]} = provisioned_package!("foreign", 1)

      {:ok,
       package: package,
       bound: bound,
       first_rule: first_rule,
       second_rule: second_rule,
       foreign_rule: foreign_rule,
       disabled_rule: disabled_rule,
       unprovisioned_rule: unprovisioned_rule}
    end

    test "accepts a rule provisioned for the same package and mints one grant per requirement",
         %{package: package, bound: bound, first_rule: first_rule, second_rule: second_rule} do
      invocation =
        in_memory_invocation(
          package,
          %{
            "source_account" => @source_requirement,
            "destination_account" => @destination_requirement
          },
          %{"destination_rule_id" => to_string(first_rule.id)}
        )

      assert {:ok, prepared} =
               CredentialGrants.prepare_launch(invocation, bound,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )

      assert %{"credential_brokers" => [_first, _second]} = prepared.payload_fields

      assert_received {:grant_attrs, first_attrs}
      assert_received {:grant_attrs, second_attrs}

      grants =
        Map.new([first_attrs, second_attrs], &{&1.metadata["requirement_name"], &1})

      destination = grants["destination_account"]
      assert to_string(destination.secret_id) == to_string(first_rule.secret_id)
      assert destination.credential_rule_id == to_string(first_rule.id)
      assert destination.metadata["credential_source"] == "package_rule"
      assert destination.allowed_hosts == ["api.example.com"]

      source = grants["source_account"]
      assert source.secret_ref == secret_ref(second_rule.secret_id)
      assert to_string(source.credential_rule_id) == to_string(second_rule.id)
    end

    test "rejects another package's rule, a disabled rule, an unprovisioned rule and a raw secret id",
         %{package: package, bound: bound} = context do
      rejected = [
        context.foreign_rule.id,
        context.disabled_rule.id,
        context.unprovisioned_rule.id,
        context.first_rule.secret_id,
        "not-a-rule-id"
      ]

      for value <- rejected do
        invocation =
          in_memory_invocation(
            package,
            %{"destination_account" => @destination_requirement},
            %{"destination_rule_id" => to_string(value)}
          )

        assert {:error,
                {:credential_rule_not_eligible, "destination_account", "destination_rule_id"}} =
                 CredentialGrants.prepare_launch(invocation, bound,
                   grant_issuer: {FakeGrantIssuer, :issue}
                 ),
               "expected #{inspect(value)} to be rejected"
      end

      invocation =
        in_memory_invocation(package, %{"destination_account" => @destination_requirement}, %{})

      assert {:error,
              {:missing_credential_rule_input, "destination_account", "destination_rule_id"}} =
               CredentialGrants.prepare_launch(invocation, bound,
                 grant_issuer: {FakeGrantIssuer, :issue}
               )

      refute_received {:grant_attrs, _attrs}
    end

    test "the action catalog lists only eligible rules, by id and name",
         %{package: package, first_rule: first_rule, second_rule: second_rule} do
      {:ok, descriptor} =
        plugin_descriptor(package, %{"destination_account" => @destination_requirement},
          scopes: ["device"]
        )

      launch_scope = %{
        actor: %{
          id: Ash.UUID.generate(),
          email: "northbound-launcher@serviceradar.local",
          role: :viewer,
          permissions: MapSet.new(["northbound.actions.launch"])
        }
      }

      assert [action] =
               launch_scope
               |> Catalog.eligible_device_actions()
               |> Enum.filter(&(&1.descriptor_id == descriptor.id))

      property = action.input_schema["properties"]["destination_rule_id"]

      expected =
        [first_rule, second_rule]
        |> Enum.sort_by(&String.downcase(&1.name))
        |> Enum.map(&%{"id" => to_string(&1.id), "label" => &1.name})

      assert property["x-credential-rule-options"] == expected
      assert property["enum"] == Enum.map(expected, & &1["id"])
      assert property["type"] == "string"
      refute inspect(action) =~ to_string(first_rule.secret_id)
      refute inspect(action) =~ to_string(second_rule.secret_id)

      assert {:ok, %{"destination_rule_id" => ^expected}} =
               PluginPackageContext.rule_options(descriptor, descriptor.provider)
    end
  end

  defp provisioned_package!(label, rule_count) do
    unique = System.unique_integer([:positive])
    provider = "example-sat-#{label}-#{unique}"
    package = approved_package!("example-sat-#{label}-#{unique}", provider)

    rules =
      for index <- 1..rule_count do
        rule!(provider, "northbound-#{label}-agent-#{unique}-#{index}")
      end

    :ok = provision!(package, rules)

    %{package: package, rules: rules, assignments: Enum.map(rules, &assignment_for!/1)}
  end

  defp assignment_for!(rule) do
    policy_id = PluginIntegrationProvisioner.policy_id_for_rule_id(rule.id)

    assert {:ok, [assignment]} =
             PluginIntegrationProvisioner.AssignmentStore.list_policy_assignments(
               policy_id,
               @system_actor
             )

    assignment
  end

  defp provision!(package, rules) do
    assert {:ok, catalog} = IntegrationCatalog.from_packages([package])

    assert {:ok, _summary} =
             PluginIntegrationProvisioner.reconcile_all(
               actor: @system_actor,
               rules: rules,
               profiles: catalog.credential_profiles
             )

    :ok
  end

  defp rule!(provider, agent_uid) do
    register_control_session!(agent_uid)

    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example account #{System.unique_integer([:positive])}",
          provider: provider,
          auth_method: "username_password",
          purpose: "device_inventory",
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: agent_uid,
          secret_id: CredentialIntegrationFixtures.secret_id!(),
          enabled: true,
          metadata: %{
            "plugin_integration" => true,
            "plugin_config" => %{},
            "schedule_enabled" => true,
            "cadence_seconds" => 86_400
          }
        },
        actor: @system_actor
      )
      |> Ash.create(actor: @system_actor)

    rule
  end

  defp approved_package!(plugin_id, provider) do
    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Satellite"},
        actor: @system_actor
      )
      |> Ash.create(actor: @system_actor)

    manifest = %{
      "id" => plugin_id,
      "name" => "Example Satellite",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result", "http_request", "producer-schedule:v1"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 64,
        "requested_cpu_ms" => 10_000,
        "max_open_connections" => 4
      },
      "producer_schedules" => [
        %{
          "schedule_id" => @schedule_id,
          "label" => "Refresh example satellite inventory",
          "action_id" => @schedule_id,
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "settings_schema" => %{"type" => "object"},
          "credential_requirements" => %{@schedule_ref => %{"required" => true}}
        }
      ],
      "integrations" => %{
        "credential_profiles" => [
          %{
            "provider" => provider,
            "label" => "Example Satellite",
            "auth_methods" => [
              %{
                "id" => "username_password",
                "label" => "Client credentials",
                "credential_kind" => "username_password",
                "fields" => [
                  %{
                    "id" => "username",
                    "label" => "Client ID",
                    "control" => "text",
                    "required" => true,
                    "secret" => false,
                    "public" => true
                  },
                  %{
                    "id" => "password",
                    "label" => "Client secret",
                    "control" => "password",
                    "required" => true,
                    "secret" => true
                  }
                ]
              }
            ],
            "purposes" => ["device_inventory"],
            "scope_types" => ["agent"],
            "provisioning" => %{
              "mode" => "producer_schedule",
              "schedule_id" => @schedule_id,
              "credential_requirement" => @schedule_ref
            }
          }
        ]
      }
    }

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Example Satellite",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          producer_schedules: manifest["producer_schedules"],
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}-1.0.0",
          signature: %{},
          source_type: :upload
        },
        actor: @system_actor
      )
      |> Ash.create(actor: @system_actor)

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: @system_actor)
      |> Ash.update(actor: @system_actor)

    package
  end

  defp plugin_descriptor(package, requirements, opts \\ []) do
    {:ok, provider} =
      ActionProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example Satellite",
          provider_type: :wasm_plugin,
          plugin_package_id: package.id,
          source_ref: "plugin_package:#{package.id}",
          approved_capabilities: [],
          credential_requirements: %{},
          metadata: %{}
        },
        actor: @system_actor
      )
      |> Ash.create(actor: @system_actor, domain: Northbound)

    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:activate, %{}, actor: @system_actor)
      |> Ash.update(actor: @system_actor, domain: Northbound)

    with {:ok, descriptor} <-
           ActionDescriptor
           |> Ash.Changeset.for_create(
             :upsert,
             %{
               provider_id: provider.id,
               action_id: "example-sat.move_terminal",
               version: "1.0.0",
               label: "Move terminal",
               scopes: Keyword.get(opts, :scopes, ["event"]),
               required_context: [],
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"destination_rule_id" => %{"type" => "string"}}
               },
               safety_classification: :destructive,
               requires_confirmation: true,
               timeout_seconds: 60,
               credential_requirements: requirements,
               result_schema_version: "serviceradar.northbound_action_result.v1",
               descriptor_hash: "test-plugin-credentials",
               enabled: true,
               metadata: %{}
             },
             actor: @system_actor
           )
           |> Ash.create(actor: @system_actor, domain: Northbound) do
      {:ok, %{descriptor | provider: provider}}
    end
  end

  defp create_event_invocation(descriptor) do
    InvocationService.create_invocation(
      %{
        descriptor_id: descriptor.id,
        targets: [%{kind: :event, event_id: "event-#{System.unique_integer([:positive])}"}],
        input_values: %{}
      },
      actor: @system_actor
    )
  end

  defp in_memory_invocation(package, requirements, input_values) do
    %ActionInvocation{
      id: Ecto.UUID.generate(),
      provider_id: Ecto.UUID.generate(),
      descriptor_id: Ecto.UUID.generate(),
      action_id: "example-sat.move_terminal",
      action_version: "1.0.0",
      descriptor_hash: "sha256:test",
      requested_by_actor_id: Ecto.UUID.generate(),
      provider: %ActionProvider{
        provider_type: :wasm_plugin,
        plugin_package_id: package.id,
        credential_requirements: %{},
        metadata: %{}
      },
      descriptor: %ActionDescriptor{
        credential_requirements: requirements,
        timeout_seconds: 60,
        metadata: %{}
      },
      target_snapshots: [%{"kind" => "device", "device_uid" => "sr:example-sat-terminal"}],
      input_values: input_values,
      redacted_input_values: %{},
      metadata: %{}
    }
  end

  defp secret_ref(secret_id), do: "credentialref:network-credential-secret:#{secret_id}"

  defp register_control_session!(agent_uid) do
    assert {:ok, _pid} =
             ProcessRegistry.register(
               {:agent_control, @partition_id, agent_uid, node()},
               %{
                 agent_id: agent_uid,
                 partition_id: @partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    await_control_partition!(agent_uid, 40)
  end

  defp await_control_partition!(_agent_uid, 0),
    do: flunk("test control-session partition did not converge")

  defp await_control_partition!(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(@partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: @partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_control_partition!(agent_uid, attempts - 1)
    end
  end
end
