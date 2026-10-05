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

  defmodule RevokedPackageAssignmentStore do
    @moduledoc false

    def list_policy_assignments("network-credential-rule:" <> rest = policy_id, _actor) do
      [rule_id | _suffix] = String.split(rest, ":")

      {:ok,
       [
         %{
           id: "assignment-#{rule_id}",
           agent_uid: "agent-k8s",
           enabled: true,
           plugin_package_id: "package-#{rule_id}",
           policy_id: policy_id
         }
       ]}
    end

    def approved_package_ids(_package_ids, _actor),
      do: {:ok, MapSet.new(["package-rule-approved"])}

    def update_assignment(assignment, attrs, _actor) do
      send(self(), {:update_assignment, assignment.id, attrs})
      {:ok, Map.merge(assignment, attrs)}
    end
  end

  defmodule RevokedPackageScheduleStore do
    @moduledoc false

    def list_assignment_schedules(assignment_id, _actor),
      do: {:ok, [%{id: "schedule-#{assignment_id}", enabled: true}]}

    def update_schedule(schedule, attrs, _actor) do
      send(self(), {:update_schedule, schedule.id, attrs})
      {:ok, Map.merge(schedule, attrs)}
    end
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
    # These are owned by PluginCredentialRuleReconcileWorker, which drives
    # PluginAssignmentMaterializer. IntegrationCatalog only attaches a
    # "producer_schedule" when the provisioning mode is "producer_schedule", so
    # one reaching this provisioner has no schedule at all.
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
  end

  describe "a package upgrade repoints the assignment" do
    defmodule RepointAssignmentStore do
      @moduledoc false

      def list_policy_assignments(policy_id, _actor) do
        {:ok,
         [
           %{
             id: "assignment-agent-k8s",
             agent_uid: "agent-k8s",
             plugin_package_id: "package-superseded",
             source: :policy,
             source_key: "plugin-credential-rule:rule-example:agent-k8s",
             policy_id: policy_id,
             enabled: true,
             interval_seconds: 86_400,
             timeout_seconds: 900,
             params: %{
               "endpoint" => "https://inventory.example.test/api",
               "filters" => [%{"name" => "switches", "type" => "Switch"}]
             }
           }
         ]}
      end

      def update_assignment(assignment, attrs, _actor) do
        send(self(), {:update_assignment, attrs.plugin_package_id})
        {:ok, Map.merge(assignment, attrs)}
      end
    end

    defmodule RepointScheduleStore do
      @moduledoc false

      def get_package_schedule(package_id, schedule_id, _actor) do
        {:ok,
         %{
           id: "schedule-successor",
           enabled: false,
           schedule_id: schedule_id,
           schedule_type: :interval,
           cadence_seconds: 86_400,
           plugin_assignment_id: nil,
           plugin_package_id: package_id,
           params: %{},
           credential_refs: %{},
           metadata: %{}
         }}
      end

      def list_assignment_schedules(_assignment_id, _actor) do
        {:ok,
         [
           %{
             id: "schedule-superseded",
             enabled: true,
             plugin_package_id: "package-superseded",
             schedule_id: "example-inventory.refresh"
           }
         ]}
      end

      def update_schedule(schedule, attrs, _actor) do
        send(self(), {:update_schedule, schedule.id, attrs})
        {:ok, Map.merge(schedule, attrs)}
      end
    end

    test "disables the superseded package's schedule when the assignment moves" do
      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules(
                 [integration_rule()],
                 [integration_profile()],
                 actor: %{id: "system"},
                 assignment_store: RepointAssignmentStore,
                 schedule_store: RepointScheduleStore
               )

      assert_receive {:update_assignment, "package-example"}
      assert_receive {:update_schedule, "schedule-superseded", %{enabled: false}}
      assert_receive {:update_schedule, "schedule-successor", _attrs}
      assert summary.schedules_disabled == 1
    end
  end

  describe "a producer-schedule package that is no longer approved" do
    # Revoking a package drops its profile from the catalog, so these rules
    # arrive with no profile at all. The package status of the provisioner's own
    # assignment decides; the missing profile does not.
    test "disables the assignment and schedule of a revoked package, not of an approved one" do
      rules = [
        integration_rule(%{id: "rule-revoked", provider: "revoked-inventory"}),
        integration_rule(%{id: "rule-approved", provider: "unlisted-inventory"})
      ]

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules(rules, [],
                 actor: %{id: "system"},
                 assignment_store: RevokedPackageAssignmentStore,
                 schedule_store: RevokedPackageScheduleStore
               )

      assert_receive {:update_assignment, "assignment-rule-revoked", %{enabled: false}}
      assert_receive {:update_schedule, "schedule-assignment-rule-revoked", %{enabled: false}}
      refute_received {:update_assignment, "assignment-rule-approved", _attrs}
      refute_received {:update_schedule, "schedule-assignment-rule-approved", _attrs}

      assert summary.rules == 1
      assert summary.assignments_disabled == 1
      assert summary.schedules_disabled == 1
    end
  end

  describe "a profile that binds several schedules with schedule_ids" do
    defmodule MultiScheduleDisableAssignmentStore do
      @moduledoc false

      def list_policy_assignments(policy_id, _actor) do
        {:ok,
         [
           %{
             id: "assignment-agent-k8s",
             agent_uid: "agent-k8s",
             enabled: true,
             plugin_package_id: "package-example",
             policy_id: policy_id
           }
         ]}
      end

      def update_assignment(assignment, attrs, _actor) do
        send(self(), {:update_assignment, assignment.id, attrs})
        {:ok, Map.merge(assignment, attrs)}
      end
    end

    defmodule MultiScheduleBoundScheduleStore do
      @moduledoc false

      def get_package_schedule(package_id, schedule_id, _actor) do
        {:ok,
         %{
           id: "schedule-#{schedule_id}",
           enabled: true,
           schedule_id: schedule_id,
           schedule_type: :interval,
           cadence_seconds: 86_400,
           plugin_assignment_id: nil,
           plugin_package_id: package_id,
           params: %{},
           credential_refs: %{},
           metadata: %{}
         }}
      end

      # Both schedules of the package are already bound to the rule's assignment.
      def list_assignment_schedules(_assignment_id, _actor) do
        {:ok,
         [
           %{
             id: "schedule-example-inventory.refresh",
             enabled: true,
             plugin_package_id: "package-example",
             schedule_id: "example-inventory.refresh"
           },
           %{
             id: "schedule-example-inventory.telemetry",
             enabled: true,
             plugin_package_id: "package-example",
             schedule_id: "example-inventory.telemetry"
           }
         ]}
      end

      def update_schedule(schedule, attrs, _actor) do
        send(self(), {:update_schedule, schedule.id, attrs})
        {:ok, Map.merge(schedule, attrs)}
      end
    end

    test "one rule binds every listed schedule to one assignment with per-schedule cadence" do
      # The rule overrides the cadence. The override moves the primary (first
      # listed) schedule only; the telemetry schedule keeps its own default.
      rule =
        integration_rule(%{
          metadata: Map.put(integration_rule().metadata, "cadence_seconds", 7_200)
        })

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules([rule], [multi_schedule_profile()],
                 actor: %{id: "system"},
                 assignment_store: AssignmentStore,
                 schedule_store: ScheduleStore
               )

      assert summary.rules == 1
      assert summary.assignments_written == 1
      assert summary.schedules_bound == 2

      assert_receive {:create_assignment, assignment}
      refute_received {:create_assignment, _second}
      # The assignment is sized by the primary schedule.
      assert assignment.interval_seconds == 86_400

      assert_receive {:update_schedule, "example-inventory.refresh", refresh}
      assert_receive {:update_schedule, "example-inventory.telemetry", telemetry}

      assert refresh.cadence_seconds == 7_200
      assert telemetry.cadence_seconds == 60

      for schedule <- [refresh, telemetry] do
        assert schedule.plugin_assignment_id == "assignment-agent-k8s"
        assert schedule.params == assignment.params
        assert schedule.enabled == false

        assert schedule.credential_refs == %{
                 "inventory_account" => "credentialref:network-credential-secret:secret-example"
               }

        assert schedule.metadata["credential_rule_id"] == "rule-example"
      end
    end

    test "reconcile_rule reports the primary schedule and every bound schedule" do
      assert {:ok, result} =
               PluginIntegrationProvisioner.reconcile_rule(
                 integration_rule(),
                 multi_schedule_profile(),
                 actor: %{id: "system"},
                 assignment_store: AssignmentStore,
                 schedule_store: ScheduleStore
               )

      assert result.schedule.schedule_id == "example-inventory.refresh"

      assert Enum.map(result.schedules, & &1.schedule_id) == [
               "example-inventory.refresh",
               "example-inventory.telemetry"
             ]

      assert result.schedules_changed == 2
      assert result.schedule_changed?
    end

    test "a listed schedule the profile carries no contract for fails before any write" do
      profile =
        Map.update!(multi_schedule_profile(), "producer_schedules", &Enum.take(&1, 1))

      assert {:error,
              {:missing_producer_schedule, "example-inventory-plugin",
               "example-inventory.telemetry"}} =
               PluginIntegrationProvisioner.reconcile_rule(integration_rule(), profile,
                 actor: %{id: "system"},
                 assignment_store: AssignmentStore,
                 schedule_store: ScheduleStore
               )

      refute_received {:create_assignment, _attrs}
      refute_received {:update_schedule, _id, _attrs}
    end

    test "disabling the rule disables every schedule bound to its assignment" do
      rule = integration_rule(%{enabled: false})

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules([rule], [multi_schedule_profile()],
                 actor: %{id: "system"},
                 assignment_store: MultiScheduleDisableAssignmentStore,
                 schedule_store: MultiScheduleBoundScheduleStore
               )

      assert_receive {:update_assignment, "assignment-agent-k8s", %{enabled: false}}

      assert_receive {:update_schedule, "schedule-example-inventory.refresh", %{enabled: false}}

      assert_receive {:update_schedule, "schedule-example-inventory.telemetry", %{enabled: false}}

      assert summary.assignments_disabled == 1
      assert summary.schedules_disabled == 2
    end

    test "a schedule dropped from the list during a package upgrade is retired while the listed one stays bound" do
      profile =
        multi_schedule_profile()
        |> put_in(["provisioning", "schedule_ids"], ["example-inventory.refresh"])
        |> Map.update!("producer_schedules", &Enum.take(&1, 1))

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules([integration_rule()], [profile],
                 actor: %{id: "system"},
                 assignment_store: __MODULE__.RepointAssignmentStore,
                 schedule_store: MultiScheduleBoundScheduleStore
               )

      assert_receive {:update_schedule, "schedule-example-inventory.telemetry", %{enabled: false}}

      assert_receive {:update_schedule, "schedule-example-inventory.refresh", refresh}
      assert refresh.plugin_assignment_id == "assignment-agent-k8s"
      refute_received {:update_schedule, "schedule-example-inventory.telemetry", _attrs}
      assert summary.schedules_disabled == 1
    end

    defmodule SamePackageShrinkAssignmentStore do
      @moduledoc false

      def list_policy_assignments(policy_id, _actor) do
        {:ok,
         [
           %{
             id: "assignment-agent-k8s",
             agent_uid: "agent-k8s",
             plugin_package_id: "package-example",
             source: :policy,
             source_key: "plugin-credential-rule:rule-example:agent-k8s",
             policy_id: policy_id,
             enabled: true,
             interval_seconds: 86_400,
             timeout_seconds: 900,
             params: %{
               "endpoint" => "https://inventory.example.test/api",
               "filters" => [%{"name" => "switches", "type" => "Switch"}]
             }
           }
         ]}
      end

      def update_assignment(assignment, attrs, _actor) do
        send(self(), {:update_assignment, assignment.id, attrs})
        {:ok, Map.merge(assignment, attrs)}
      end
    end

    test "a schedule dropped from the list of an unchanged package is retired while the listed one stays bound" do
      profile =
        multi_schedule_profile()
        |> put_in(["provisioning", "schedule_ids"], ["example-inventory.refresh"])
        |> Map.update!("producer_schedules", &Enum.take(&1, 1))

      assert {:ok, summary} =
               PluginIntegrationProvisioner.reconcile_rules([integration_rule()], [profile],
                 actor: %{id: "system"},
                 assignment_store: SamePackageShrinkAssignmentStore,
                 schedule_store: MultiScheduleBoundScheduleStore
               )

      assert_receive {:update_schedule, "schedule-example-inventory.telemetry", %{enabled: false}}

      assert_receive {:update_schedule, "schedule-example-inventory.refresh", refresh}
      assert refresh.plugin_assignment_id == "assignment-agent-k8s"
      refute_received {:update_schedule, "schedule-example-inventory.telemetry", _attrs}
      assert summary.schedules_disabled == 1
    end
  end

  test "NOM config retrieval waits for devices without disarming inventory or unrelated secondary schedules" do
    for {config, retrieve_enabled} <- [
          {%{}, false},
          {%{"devices" => []}, false},
          {%{"devices" => [], "device_id" => "1001", "device_uid" => "sr:host01.example.com"},
           false},
          {%{"devices" => [%{"device_id" => "1001", "device_uid" => "sr:host01.example.com"}]},
           true},
          {%{"device_id" => "1001", "device_uid" => "sr:host01.example.com"}, true}
        ] do
      profile = multi_schedule_profile()

      retrieve =
        profile["producer_schedules"]
        |> List.last()
        |> Map.put("schedule_id", "opentext-nom.config.retrieve")

      profile =
        profile
        |> put_in(["provisioning", "schedule_ids"], [
          "example-inventory.refresh",
          "opentext-nom.config.retrieve",
          "example-inventory.telemetry"
        ])
        |> Map.update!("producer_schedules", &(&1 ++ [retrieve]))
        |> put_in(["config_schema"], %{"type" => "object"})

      rule =
        integration_rule()
        |> put_in([:metadata, "schedule_enabled"], true)
        |> put_in([:metadata, "plugin_config"], config)

      assert {:ok, result} =
               PluginIntegrationProvisioner.reconcile_rule(rule, profile,
                 actor: %{id: "system"},
                 assignment_store: AssignmentStore,
                 schedule_store: ScheduleStore
               )

      assert Enum.find(result.schedules, &(&1.schedule_id == "example-inventory.refresh")).enabled

      assert Enum.find(result.schedules, &(&1.schedule_id == "example-inventory.telemetry")).enabled

      assert Enum.find(result.schedules, &(&1.schedule_id == "opentext-nom.config.retrieve")).enabled ==
               retrieve_enabled
    end
  end

  defp multi_schedule_profile do
    refresh = integration_profile()["producer_schedule"]

    telemetry = %{
      "schedule_id" => "example-inventory.telemetry",
      "default_cadence_seconds" => 60,
      "min_cadence_seconds" => 30,
      "max_cadence_seconds" => 3_600,
      "timeout_seconds" => 30
    }

    integration_profile(%{
      "provisioning" => %{
        "mode" => "producer_schedule",
        "schedule_ids" => ["example-inventory.refresh", "example-inventory.telemetry"],
        "credential_requirement" => "inventory_account"
      },
      "producer_schedule" => refresh,
      "producer_schedules" => [refresh, telemetry]
    })
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
