defmodule ServiceRadar.Credentials.PluginIntegrationProvisionerStoreDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.AssignmentStore
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.ScheduleStore
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  @system_actor SystemActor.system(:plugin_integration_provisioner_store_db_test)
  @schedule_id "example-inventory.refresh"
  @partition_id "default"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  # The provisioner's unit tests inject fake stores, so these default stores are
  # the only code that names real PluginAssignment / ProducerSchedule actions and
  # fields. A store that reads through an action the resource does not define
  # raises on every reconcile pass and stops the worker.
  test "the default stores read through actions and fields the resources define" do
    policy_id = "network-credential-rule:#{Ecto.UUID.generate()}:plugin_integration"

    assert {:ok, []} = AssignmentStore.list_policy_assignments(policy_id, @system_actor)

    assert {:ok, approved} =
             AssignmentStore.approved_package_ids([Ecto.UUID.generate()], @system_actor)

    assert MapSet.size(approved) == 0

    assert {:ok, nil} =
             ScheduleStore.get_package_schedule(
               Ecto.UUID.generate(),
               "example-inventory.refresh",
               @system_actor
             )

    assert {:ok, []} =
             ScheduleStore.list_assignment_schedules(Ecto.UUID.generate(), @system_actor)
  end

  describe "a producer-schedule package that leaves :approved" do
    # Revoking a package removes its profile from the integration catalog, which
    # is built from approved packages only. Both reconciles below therefore pass
    # no profile for the rule: the only difference between the two cases is the
    # package status, which is the signal the provisioner has to act on.
    test "revocation disables the provisioned assignment and schedule on the next reconcile" do
      %{package: package, rule: rule} = provision!("revoked")

      assert {:ok, %PluginPackage{status: :revoked}} =
               package
               |> Ash.Changeset.for_update(:revoke, %{denied_reason: "test revocation"},
                 actor: admin_actor()
               )
               |> Ash.update()

      # The revoke action alone leaves both runnable; the reconcile must not.
      assert provisioned_assignment!(rule).enabled
      assert package_schedule!(package).enabled

      assert {:ok, summary} = reconcile(rule, [])
      assert summary.assignments_disabled == 1
      assert summary.schedules_disabled == 1

      refute provisioned_assignment!(rule).enabled
      refute package_schedule!(package).enabled

      # An Oban retry or the next scheduled run finds nothing left to disable.
      assert {:ok, %{assignments_disabled: 0, schedules_disabled: 0}} = reconcile(rule, [])
    end

    test "an approved package whose profile is absent keeps its assignment and schedule" do
      %{package: package, rule: rule} = provision!("approved")

      assert {:ok, summary} = reconcile(rule, [])
      assert summary.assignments_disabled == 0
      assert summary.schedules_disabled == 0

      assert provisioned_assignment!(rule).enabled
      assert package_schedule!(package).enabled
    end
  end

  defp provision!(label) do
    unique = System.unique_integer([:positive])
    agent_uid = "provisioner-agent-#{label}-#{unique}"
    register_control_session!(agent_uid)

    package = approved_package!("provisioner-#{label}-#{unique}")
    profile = producer_schedule_profile(package, "provisioner-#{label}-#{unique}")
    rule = producer_schedule_rule(agent_uid, profile["provider"])

    assert {:ok, %{assignments_written: 1, schedules_bound: 1}} = reconcile(rule, [profile])
    assert provisioned_assignment!(rule).enabled
    assert package_schedule!(package).enabled

    %{package: package, rule: rule}
  end

  defp reconcile(rule, profiles) do
    PluginIntegrationProvisioner.reconcile_all(
      actor: @system_actor,
      rules: [rule],
      profiles: profiles
    )
  end

  defp provisioned_assignment!(rule) do
    policy_id = "network-credential-rule:#{rule.id}:plugin_integration"
    assert {:ok, [assignment]} = AssignmentStore.list_policy_assignments(policy_id, @system_actor)
    assignment
  end

  defp package_schedule!(package) do
    assert {:ok, %{} = schedule} =
             ScheduleStore.get_package_schedule(package.id, @schedule_id, @system_actor)

    schedule
  end

  defp admin_actor do
    %{
      id: Ash.UUID.generate(),
      email: "provisioner-store-test@serviceradar.local",
      role: :admin,
      permissions: MapSet.new(["settings.plugins.manage"])
    }
  end

  defp approved_package!(plugin_id) do
    actor = admin_actor()

    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Inventory"},
        actor: actor
      )
      |> Ash.create()

    manifest = %{
      "id" => plugin_id,
      "name" => "Example Inventory",
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
          "label" => "Refresh example inventory",
          "action_id" => @schedule_id,
          "command_type" => "plugin.run_action",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "settings_schema" => %{"type" => "object"},
          "credential_requirements" => %{"api_token" => %{"required" => true}}
        }
      ]
    }

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Example Inventory",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          producer_schedules: manifest["producer_schedules"],
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}",
          signature: %{},
          source_type: :upload
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> Ash.update()

    package
  end

  defp producer_schedule_profile(package, provider) do
    %{
      "provider" => provider,
      "plugin_id" => package.plugin_id,
      "plugin_package_id" => package.id,
      "auth_methods" => [%{"id" => "api_token", "credential_kind" => "api_token"}],
      "purposes" => ["device_inventory"],
      "scope_types" => ["agent"],
      "config_schema" => %{},
      "provisioning" => %{
        "mode" => "producer_schedule",
        "schedule_id" => @schedule_id,
        "credential_requirement" => "api_token"
      },
      "producer_schedule" => %{
        "schedule_id" => @schedule_id,
        "default_cadence_seconds" => 86_400,
        "min_cadence_seconds" => 3_600,
        "max_cadence_seconds" => 2_592_000,
        "timeout_seconds" => 900
      }
    }
  end

  defp producer_schedule_rule(agent_uid, provider) do
    %{
      id: Ecto.UUID.generate(),
      secret_id: CredentialIntegrationFixtures.secret_id!(),
      provider: provider,
      auth_method: :api_token,
      purpose: :device_inventory,
      enabled: true,
      scope_type: :agent,
      scope_value: agent_uid,
      metadata: %{
        "plugin_integration" => true,
        "purposes" => ["device_inventory"],
        "plugin_config" => %{},
        "schedule_enabled" => true,
        "cadence_seconds" => 86_400
      }
    }
  end

  # Registered under the test process with a unique agent UID, so the entry
  # exits with this test and no other test can observe it.
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
