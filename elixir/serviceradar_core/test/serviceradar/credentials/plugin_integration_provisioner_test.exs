defmodule ServiceRadar.Credentials.PluginIntegrationProvisionerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginIntegrationProvisioner

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
