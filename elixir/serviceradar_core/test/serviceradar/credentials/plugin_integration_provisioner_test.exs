defmodule ServiceRadar.Credentials.PluginIntegrationProvisionerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Plugins.PluginAssignment

  defmodule AssignmentStore do
    @moduledoc false

    def list_policy_assignments(policy_id, _actor) do
      send(self(), {:list_policy_assignments, policy_id})
      {:ok, []}
    end

    def create_assignment(attrs, _actor) do
      send(self(), {:create_assignment, attrs})
      {:ok, Map.put(attrs, :id, "assignment-#{attrs.agent_uid}")}
    end

    def update_assignment(assignment, attrs, _actor) do
      send(self(), {:update_assignment, assignment, attrs})
      {:ok, Map.merge(assignment, attrs)}
    end
  end

  defmodule ScheduleStore do
    @moduledoc false

    def get_package_schedule(package_id, schedule_id, _actor) do
      {:ok,
       %{
         id: "schedule-#{package_id}",
         enabled: false,
         schedule_id: schedule_id,
         schedule_type: :interval,
         cadence_seconds: 86_400,
         plugin_assignment_id: nil,
         params: %{},
         credential_refs: %{},
         metadata: %{}
       }}
    end

    def update_schedule(schedule, attrs, _actor) do
      send(self(), {:update_schedule, schedule.schedule_id, attrs})
      {:ok, Map.merge(schedule, attrs)}
    end

    def list_assignment_schedules(_assignment_id, _actor), do: {:ok, []}
  end

  test "provisions package-owned config and binds its declared credential requirement" do
    rule = integration_rule()

    assert {:ok, result} =
             PluginIntegrationProvisioner.reconcile_rule(rule, integration_profile(),
               actor: %{id: "system"},
               assignment_store: AssignmentStore,
               schedule_store: ScheduleStore
             )

    assert_receive {:create_assignment, assignment}
    assert assignment.agent_uid == "agent-k8s"
    assert assignment.plugin_package_id == "package-example"
    assert assignment.source == :policy
    assert assignment.policy_id == "network-credential-rule:rule-example:plugin_integration"
    assert assignment.enabled

    assert assignment.params == %{
             "endpoint" => "https://inventory.example.test/api",
             "filters" => [%{"name" => "switches", "type" => "Switch"}]
           }

    refute Map.has_key?(assignment.params, "credential_broker")
    refute Map.has_key?(assignment.params, "credential_refs")

    assert_receive {:update_schedule, "example-inventory.refresh", schedule}
    refute schedule.enabled
    assert schedule.cadence_seconds == 86_400
    assert schedule.plugin_assignment_id == "assignment-agent-k8s"
    assert schedule.params == assignment.params

    assert schedule.credential_refs == %{
             "inventory_account" => "credentialref:network-credential-secret:secret-example"
           }

    assert schedule.metadata["credential_rule_id"] == "rule-example"
    assert schedule.metadata["integration_provider"] == "example-inventory"
    assert result.assignment_changed?
    assert result.schedule_changed?
  end

  test "supports multiple package-declared providers without core registration" do
    second_profile =
      integration_profile(%{
        "provider" => "other-inventory",
        "plugin_id" => "other-inventory-plugin",
        "plugin_package_id" => "package-other",
        "provisioning" => %{
          "mode" => "producer_schedule",
          "schedule_id" => "other-inventory.refresh",
          "credential_requirement" => "other_account"
        },
        "producer_schedule" =>
          Map.put(
            integration_profile()["producer_schedule"],
            "schedule_id",
            "other-inventory.refresh"
          )
      })

    rules = [
      integration_rule(),
      integration_rule(%{
        id: "rule-other",
        secret_id: "secret-other",
        provider: "other-inventory",
        scope_value: "agent-other"
      })
    ]

    assert {:ok, summary} =
             PluginIntegrationProvisioner.reconcile_rules(
               rules,
               [integration_profile(), second_profile],
               actor: %{},
               assignment_store: AssignmentStore,
               schedule_store: ScheduleStore
             )

    assert summary.rules == 2
    assert summary.assignments_written == 2
    assert summary.schedules_bound == 2
    assert_receive {:create_assignment, %{plugin_package_id: "package-example"}}
    assert_receive {:create_assignment, %{plugin_package_id: "package-other"}}
  end

  test "rejects auth, scope, cadence, and config outside the package contract" do
    opts = [
      actor: %{},
      assignment_store: AssignmentStore,
      schedule_store: ScheduleStore
    ]

    assert {:error, :invalid_plugin_integration_auth_method} =
             PluginIntegrationProvisioner.reconcile_rule(
               integration_rule(%{auth_method: :api_key}),
               integration_profile(),
               opts
             )

    assert {:error, :plugin_integration_requires_agent_scope} =
             PluginIntegrationProvisioner.reconcile_rule(
               integration_rule(%{scope_type: :partition, scope_value: "default"}),
               Map.put(integration_profile(), "scope_types", ["partition"]),
               opts
             )

    assert {:error, {:invalid_plugin_integration_cadence, 3_600, 2_592_000}} =
             PluginIntegrationProvisioner.reconcile_rule(
               integration_rule(%{
                 metadata: Map.put(integration_rule().metadata, "cadence_seconds", 1)
               }),
               integration_profile(),
               opts
             )

    invalid_config =
      integration_rule(%{
        metadata:
          Map.put(integration_rule().metadata, "plugin_config", %{
            "endpoint" => "http://unsafe.example.test",
            "filters" => []
          })
      })

    assert {:error, {:invalid_plugin_integration_config, errors}} =
             PluginIntegrationProvisioner.reconcile_rule(
               invalid_config,
               integration_profile(),
               opts
             )

    assert errors != []
    refute_received {:create_assignment, _attrs}
  end

  describe "profiles this provisioner does not own" do
    # IntegrationDescriptor defines three provisioning modes. Only
    # "producer_schedule" carries a schedule for this provisioner to bind, and
    # IntegrationCatalog attaches the "producer_schedule" key to that mode alone.
    #
    # credential_only is the case a denylist would miss: rejecting only
    # target_policy still lets it reach cadence validation. On demo the awx
    # profile is credential_only, so the AWX / AAP Bridge is exactly this path.
    defp credential_only_profile do
      integration_profile()
      |> Map.put("provisioning", %{"mode" => "credential_only"})
      |> Map.delete("producer_schedule")
    end

    test "credential_only is skipped, not run through cadence validation" do
      opts = [
        actor: %{id: "system"},
        assignment_store: AssignmentStore,
        schedule_store: ScheduleStore
      ]

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules(
                 [integration_rule()],
                 [credential_only_profile()],
                 opts
               )

      assert summary.rules == 0
      assert summary.assignments_disabled == 0
      refute_received {:create_assignment, _attrs}
    end
  end

  describe "target-policy profiles" do
    # These are owned by PluginTargetPolicyReconcileWorker. IntegrationCatalog only
    # attaches a "producer_schedule" when the provisioning mode is
    # "producer_schedule", so one reaching this provisioner has no schedule at all.
    #
    # On demo that was every credential rule -- two proxmox, one camera -- and
    # because reconcile_rules/3 halts on the first error, one of them stopped
    # reconciliation for all of them and the worker discarded after max_attempts.
    defp target_policy_profile do
      integration_profile()
      |> Map.put("provisioning", %{
        "mode" => "target_policy",
        "credential_requirement" => "inventory_account"
      })
      |> Map.delete("producer_schedule")
    end

    test "are skipped by reconcile_rules rather than failing the whole batch" do
      opts = [
        actor: %{id: "system"},
        assignment_store: AssignmentStore,
        schedule_store: ScheduleStore
      ]

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules(
                 [integration_rule()],
                 [target_policy_profile()],
                 opts
               )

      assert summary.rules == 0
      assert summary.assignments_written == 0
      assert summary.schedules_bound == 0
      # Skipped, NOT disabled -- these rules are valid and actively in use by the
      # other worker. Treating an unmatched profile as revoked would tear down
      # working target-policy assignments.
      assert summary.assignments_disabled == 0
      assert summary.schedules_disabled == 0
      refute_received {:create_assignment, _attrs}
      refute_received {:update_schedule, _id, _attrs}
    end

    test "one target-policy rule does not stop a producer-schedule rule beside it" do
      opts = [
        actor: %{id: "system"},
        assignment_store: AssignmentStore,
        schedule_store: ScheduleStore
      ]

      target_only = Map.put(target_policy_profile(), "provider", "camera-inventory")
      camera_rule = integration_rule(%{id: "rule-camera", provider: "camera-inventory"})

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules(
                 [camera_rule, integration_rule()],
                 [target_only, integration_profile()],
                 opts
               )

      assert summary.rules == 1
      assert_receive {:create_assignment, assignment}
      assert assignment.agent_uid == "agent-k8s"
    end

    test "a producer_schedule-mode profile missing its schedule names the schedule" do
      # Distinct from an out-of-range cadence. Indexing nil returns nil rather than
      # raising, so this used to surface as {:invalid_plugin_integration_cadence,
      # nil, nil} -- blaming the cadence for a missing schedule.
      profile = Map.delete(integration_profile(), "producer_schedule")

      assert {:error, {:missing_producer_schedule, "example-inventory-plugin"}} =
               PluginIntegrationProvisioner.reconcile_rule(integration_rule(), profile,
                 actor: %{id: "system"},
                 assignment_store: AssignmentStore,
                 schedule_store: ScheduleStore
               )
    end
  end

  test "lists existing policy assignments through PluginAssignment.all_partitions_for_policy" do
    action = Ash.Resource.Info.action(PluginAssignment, :all_partitions_for_policy)

    assert action.type == :read
    assert Enum.any?(action.arguments, &(&1.name == :policy_id))
  end

  defp integration_profile(overrides \\ %{}) do
    defaults = %{
      "provider" => "example-inventory",
      "auth_methods" => [
        %{"id" => "username_password", "credential_kind" => "username_password"}
      ],
      "purposes" => ["device_inventory"],
      "scope_types" => ["agent"],
      "plugin_id" => "example-inventory-plugin",
      "plugin_package_id" => "package-example",
      "config_schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["endpoint", "filters"],
        "properties" => %{
          "endpoint" => %{"type" => "string", "format" => "uri", "pattern" => "^https://"},
          "filters" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["name", "type"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "type" => %{"type" => "string"}
              }
            }
          }
        }
      },
      "provisioning" => %{
        "mode" => "producer_schedule",
        "schedule_id" => "example-inventory.refresh",
        "credential_requirement" => "inventory_account"
      },
      "producer_schedule" => %{
        "schedule_id" => "example-inventory.refresh",
        "default_cadence_seconds" => 86_400,
        "min_cadence_seconds" => 3_600,
        "max_cadence_seconds" => 2_592_000,
        "timeout_seconds" => 900
      }
    }

    Map.merge(defaults, overrides)
  end

  defp integration_rule(overrides \\ %{}) do
    defaults = %{
      id: "rule-example",
      secret_id: "secret-example",
      provider: "example-inventory",
      auth_method: :username_password,
      purpose: :device_inventory,
      enabled: true,
      scope_type: :agent,
      scope_value: "agent-k8s",
      metadata: %{
        "plugin_integration" => true,
        "purposes" => ["device_inventory"],
        "plugin_config" => %{
          "endpoint" => "https://inventory.example.test/api",
          "filters" => [%{"name" => "switches", "type" => "Switch"}]
        },
        "schedule_enabled" => false,
        "cadence_seconds" => 86_400
      }
    }

    Map.merge(defaults, overrides)
  end
end
