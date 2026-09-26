defmodule ServiceRadar.Credentials.PluginIntegrationProvisionerStoreDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.AssignmentStore
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.ScheduleStore

  @moduletag :integration

  @system_actor SystemActor.system(:plugin_integration_provisioner_store_db_test)

  # The provisioner's unit tests inject fake stores, so these default stores are
  # the only code that names real PluginAssignment / ProducerSchedule actions and
  # fields. A store that reads through an action the resource does not define
  # raises on every reconcile pass and stops the worker.
  test "the default stores read through actions and fields the resources define" do
    policy_id = "network-credential-rule:#{Ecto.UUID.generate()}:plugin_integration"

    assert {:ok, []} = AssignmentStore.list_policy_assignments(policy_id, @system_actor)

    assert {:ok, nil} =
             ScheduleStore.get_package_schedule(
               Ecto.UUID.generate(),
               "example-inventory.refresh",
               @system_actor
             )

    assert {:ok, []} =
             ScheduleStore.list_assignment_schedules(Ecto.UUID.generate(), @system_actor)
  end
end
