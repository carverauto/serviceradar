defmodule ServiceRadar.Credentials.HpnaInventoryProvisionerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.HpnaInventoryProvisioner

  defmodule AssignmentStore do
    @moduledoc false

    def list_policy_assignments(policy_id, _actor) do
      send(self(), {:list_policy_assignments, policy_id})
      {:ok, []}
    end

    def create_assignment(attrs, _actor) do
      send(self(), {:create_assignment, attrs})
      {:ok, Map.put(attrs, :id, "assignment-hpna")}
    end

    def update_assignment(assignment, attrs, _actor) do
      send(self(), {:update_assignment, assignment, attrs})
      {:ok, Map.merge(assignment, attrs)}
    end
  end

  defmodule ScheduleStore do
    @moduledoc false

    def get_package_schedule("package-hpna", "hpna.inventory.refresh", _actor) do
      {:ok,
       %{
         id: "schedule-hpna",
         enabled: false,
         schedule_type: :interval,
         cadence_seconds: 86_400,
         plugin_assignment_id: nil,
         params: %{},
         credential_refs: %{},
         metadata: %{}
       }}
    end

    def update_schedule(schedule, attrs, _actor) do
      send(self(), {:update_schedule, attrs})
      {:ok, Map.merge(schedule, attrs)}
    end

    def list_assignment_schedules(_assignment_id, _actor), do: {:ok, []}
  end

  test "provisions direct action-only config and binds the disabled daily schedule" do
    rule = hpna_rule()

    assert {:ok, result} =
             HpnaInventoryProvisioner.reconcile_rule(rule,
               actor: %{id: "system"},
               plugin_package: %{id: "package-hpna", version: "0.1.0"},
               assignment_store: AssignmentStore,
               schedule_store: ScheduleStore
             )

    assert_receive {:create_assignment, assignment}
    assert assignment.agent_uid == "agent-k8s"
    assert assignment.source == :policy
    assert assignment.policy_id == "network-credential-rule:rule-hpna:device_inventory"
    assert assignment.enabled
    assert assignment.params["instance_id"] == "example-automation-prod"

    assert assignment.params["queries"] == [
             %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
           ]

    refute Map.has_key?(assignment.params, "credential_broker")
    refute Map.has_key?(assignment.params, "credential_refs")

    assert_receive {:update_schedule, schedule}
    assert schedule.enabled == false
    assert schedule.schedule_type == :interval
    assert schedule.cadence_seconds == 86_400
    assert schedule.plugin_assignment_id == "assignment-hpna"
    assert schedule.params == assignment.params

    assert schedule.credential_refs == %{
             "hpna_service_account" => "credentialref:network-credential-secret:secret-hpna"
           }

    assert schedule.metadata["credential_rule_id"] == "rule-hpna"
    assert schedule.metadata["hpna_instance_id"] == "example-automation-prod"
    refute inspect(schedule) =~ "service-account-password"
    assert result.assignment_changed?
    assert result.schedule_changed?
  end

  test "rejects multiple enabled HPNA rules before provisioning" do
    assert {:error, {:multiple_enabled_hpna_credential_rules, 2}} =
             HpnaInventoryProvisioner.reconcile_rules([
               hpna_rule(),
               hpna_rule(%{id: "rule-hpna-2", scope_value: "agent-b"})
             ])

    refute_received {:create_assignment, _attrs}
  end

  test "requires username-password auth and selected-agent scope" do
    assert {:error, :invalid_hpna_auth_method} =
             HpnaInventoryProvisioner.reconcile_rule(
               hpna_rule(%{auth_method: :api_key}),
               actor: %{},
               plugin_package: %{id: "package-hpna"},
               assignment_store: AssignmentStore,
               schedule_store: ScheduleStore
             )

    assert {:error, :hpna_requires_agent_scope} =
             HpnaInventoryProvisioner.reconcile_rule(
               hpna_rule(%{scope_type: :partition}),
               actor: %{},
               plugin_package: %{id: "package-hpna"},
               assignment_store: AssignmentStore,
               schedule_store: ScheduleStore
             )
  end

  defp hpna_rule(overrides \\ %{}) do
    defaults = %{
      id: "rule-hpna",
      secret_id: "secret-hpna",
      provider: "hpna",
      auth_method: :username_password,
      purpose: :device_inventory,
      enabled: true,
      scope_type: :agent,
      scope_value: "agent-k8s",
      metadata: %{
        "purposes" => ["device_inventory"],
        "instance_id" => "example-automation-prod",
        "token_url" => "https://hpna.example.test/oauth/token",
        "api_url" => "https://hpna.example.test/api/automation/wrapper",
        "schedule_enabled" => false,
        "cadence_seconds" => 86_400
      }
    }

    Map.merge(defaults, overrides)
  end
end
