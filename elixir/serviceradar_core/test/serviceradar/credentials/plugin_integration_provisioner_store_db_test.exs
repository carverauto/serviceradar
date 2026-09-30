defmodule ServiceRadar.Credentials.PluginIntegrationProvisionerStoreDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.AssignmentStore
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner.ScheduleStore
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  @system_actor SystemActor.system(:plugin_integration_provisioner_store_db_test)
  @schedule_id "example-inventory.refresh"
  @telemetry_schedule_id "example-inventory.telemetry"
  @partition_id "default"

  setup_all do
    TestSupport.start_core!()
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

    test "repointing onto a successor package disables the superseded schedule" do
      %{package: superseded, rule: rule} = provision!("upgrade")
      assert package_schedule!(superseded).enabled

      assert {:ok, %PluginPackage{status: :revoked}} =
               superseded
               |> Ash.Changeset.for_update(:revoke, %{denied_reason: "superseded"},
                 actor: admin_actor()
               )
               |> Ash.update()

      successor =
        approved_package!(superseded.plugin_id, version: "1.1.0", create_plugin: false)

      assert {:ok, summary} =
               reconcile(rule, [producer_schedule_profile(successor, rule.provider)])

      assert summary.schedules_disabled == 1
      refute package_schedule!(superseded).enabled
      assert package_schedule!(successor).enabled
      assert to_string(provisioned_assignment!(rule).plugin_package_id) == to_string(successor.id)
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

  describe "one rule driving several schedules of one package" do
    test "binds both schedules to one assignment, each at its own cadence" do
      %{package: package, rule: rule} = provision_multi!("bind")

      assignment = provisioned_assignment!(rule)
      refresh = package_schedule!(package)
      telemetry = package_schedule!(package, @telemetry_schedule_id)

      for schedule <- [refresh, telemetry] do
        assert schedule.enabled
        assert schedule.plugin_assignment_id == assignment.id
        assert schedule.credential_refs == %{"api_token" => credential_ref(rule)}
        assert schedule.metadata["credential_rule_id"] == rule.id
      end

      # The rule's cadence override (7200) moves the primary only.
      assert refresh.cadence_seconds == 7_200
      assert telemetry.cadence_seconds == 60

      # A second pass over unchanged state writes nothing.
      assert {:ok, %{assignments_written: 0, schedules_bound: 0}} =
               reconcile(rule, [multi_schedule_profile(package, rule.provider)])
    end

    test "disabling the rule disables every bound schedule" do
      %{package: package, rule: rule} = provision_multi!("disable")

      assert {:ok, summary} =
               reconcile(%{rule | enabled: false}, [
                 multi_schedule_profile(package, rule.provider)
               ])

      assert summary.assignments_disabled == 1
      assert summary.schedules_disabled == 2

      refute provisioned_assignment!(rule).enabled
      refute package_schedule!(package).enabled
      refute package_schedule!(package, @telemetry_schedule_id).enabled
    end

    test "a successor version that drops a schedule id retires that schedule" do
      %{package: v1, rule: rule} = provision_multi!("drop")

      v2 =
        approved_package!(v1.plugin_id,
          version: "1.1.0",
          create_plugin: false,
          schedules: [refresh_contract(), telemetry_contract()]
        )

      profile =
        v2
        |> multi_schedule_profile(rule.provider)
        |> put_in(["provisioning", "schedule_ids"], [@schedule_id])
        |> Map.update!("producer_schedules", &Enum.take(&1, 1))

      assert {:ok, summary} = reconcile(rule, [profile])
      assert summary.schedules_disabled == 2
      assert summary.schedules_bound == 1

      refute package_schedule!(v1).enabled
      refute package_schedule!(v1, @telemetry_schedule_id).enabled

      assignment = provisioned_assignment!(rule)
      assert to_string(assignment.plugin_package_id) == to_string(v2.id)
      assert package_schedule!(v2).enabled
      assert package_schedule!(v2).plugin_assignment_id == assignment.id

      # The dropped schedule exists in the successor package but nothing binds it.
      dropped = package_schedule!(v2, @telemetry_schedule_id)
      refute dropped.enabled
      assert is_nil(dropped.plugin_assignment_id)
    end
  end

  defp provision_multi!(label) do
    unique = System.unique_integer([:positive])
    agent_uid = "provisioner-agent-#{label}-#{unique}"
    register_control_session!(agent_uid)

    package =
      approved_package!("provisioner-#{label}-#{unique}",
        schedules: [refresh_contract(), telemetry_contract()]
      )

    profile = multi_schedule_profile(package, "provisioner-#{label}-#{unique}")

    rule =
      agent_uid
      |> producer_schedule_rule(profile["provider"])
      |> Map.update!(:metadata, &Map.put(&1, "cadence_seconds", 7_200))

    assert {:ok, %{assignments_written: 1, schedules_bound: 2}} = reconcile(rule, [profile])
    %{package: package, rule: rule}
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

  defp package_schedule!(package, schedule_id \\ @schedule_id) do
    assert {:ok, %{} = schedule} =
             ScheduleStore.get_package_schedule(package.id, schedule_id, @system_actor)

    schedule
  end

  defp credential_ref(rule),
    do: ServiceRadar.Plugins.SecretRefs.network_credential_ref(rule.secret_id)

  defp admin_actor do
    %{
      id: Ash.UUID.generate(),
      email: "provisioner-store-test@serviceradar.local",
      role: :admin,
      permissions: MapSet.new(["settings.plugins.manage"])
    }
  end

  defp approved_package!(plugin_id, opts \\ []) do
    actor = admin_actor()
    version = Keyword.get(opts, :version, "1.0.0")

    if Keyword.get(opts, :create_plugin, true) do
      {:ok, _plugin} =
        Plugin
        |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Inventory"},
          actor: actor
        )
        |> Ash.create()
    end

    manifest = %{
      "id" => plugin_id,
      "name" => "Example Inventory",
      "version" => version,
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result", "http_request", "producer-schedule:v1"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 64,
        "requested_cpu_ms" => 10_000,
        "max_open_connections" => 4
      },
      "producer_schedules" => Keyword.get(opts, :schedules, [refresh_contract()])
    }

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Example Inventory",
          version: version,
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          producer_schedules: manifest["producer_schedules"],
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}-#{version}",
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

  defp refresh_contract do
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
  end

  defp telemetry_contract do
    %{
      "schedule_id" => @telemetry_schedule_id,
      "label" => "Collect example telemetry",
      "action_id" => @telemetry_schedule_id,
      "command_type" => "plugin.run_action",
      "default_cadence_seconds" => 60,
      "min_cadence_seconds" => 30,
      "max_cadence_seconds" => 3_600,
      "settings_schema" => %{"type" => "object"},
      "credential_requirements" => %{"api_token" => %{"required" => true}}
    }
  end

  defp multi_schedule_profile(package, provider) do
    refresh = Map.put(Map.take(refresh_contract(), catalog_keys()), "timeout_seconds", 900)
    telemetry = Map.put(Map.take(telemetry_contract(), catalog_keys()), "timeout_seconds", 30)

    package
    |> producer_schedule_profile(provider)
    |> Map.put("provisioning", %{
      "mode" => "producer_schedule",
      "schedule_ids" => [@schedule_id, @telemetry_schedule_id],
      "credential_requirement" => "api_token"
    })
    |> Map.put("producer_schedule", refresh)
    |> Map.put("producer_schedules", [refresh, telemetry])
  end

  defp catalog_keys,
    do: ~w(schedule_id default_cadence_seconds min_cadence_seconds max_cadence_seconds)

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

  # Registered through the canonical helper, which scopes the session to this
  # test's sandbox: the entry is owned by the calling test process (it exits
  # with this test) and is skipped by other concurrent tests' config pushes.
  defp register_control_session!(agent_uid) do
    TestSupport.register_agent_control_session!(agent_uid, @partition_id)
  end
end
