defmodule ServiceRadar.Plugins.ProducerScheduleTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.ProducerScheduleDispatcher

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :admin,
      permissions: MapSet.new(["settings.plugins.manage", "settings.integrations.manage"])
    }

    {:ok, actor: actor, uid: :erlang.unique_integer([:positive])}
  end

  test "package producer schedule contracts materialize as disabled schedule state", %{
    actor: actor,
    uid: uid
  } do
    plugin_id = "advisory-producer-#{uid}"

    assert {:ok, package} = create_package(actor, plugin_id)

    assert {:ok, schedule} =
             ProducerSchedule
             |> Ash.Query.filter(
               producer_kind == :wasm_plugin and plugin_package_id == ^package.id and
                 schedule_id == "advisory.refresh"
             )
             |> Ash.read_one(actor: actor)

    assert schedule.enabled == false
    assert schedule.display_name == "Refresh advisory feed"
    assert schedule.cadence_seconds == 86_400
    assert schedule.contract["action_id"] == "advisory.refresh"
  end

  test "package producer schedule contracts materialize on package update", %{
    actor: actor,
    uid: uid
  } do
    plugin_id = "updated-advisory-producer-#{uid}"

    assert {:ok, package} = create_package(actor, plugin_id)

    schedules =
      package.producer_schedules ++
        [
          %{
            "schedule_id" => "advisory.delta",
            "label" => "Refresh advisory delta feed",
            "action_id" => "advisory.delta",
            "command_type" => "plugin.run_action",
            "default_cadence_seconds" => 3_600,
            "min_cadence_seconds" => 300,
            "max_cadence_seconds" => 86_400,
            "settings_schema" => %{"type" => "object"}
          }
        ]

    assert {:ok, _updated_package} =
             package
             |> Ash.Changeset.for_update(:update, %{producer_schedules: schedules}, actor: actor)
             |> Ash.update()

    assert {:ok, schedule} =
             ProducerSchedule
             |> Ash.Query.filter(
               producer_kind == :wasm_plugin and plugin_package_id == ^package.id and
                 schedule_id == "advisory.delta"
             )
             |> Ash.read_one(actor: actor)

    assert schedule.enabled == false
    assert schedule.display_name == "Refresh advisory delta feed"
    assert schedule.cadence_seconds == 3_600
    assert schedule.contract["action_id"] == "advisory.delta"
  end

  test "operator state updates preserve package contract and build plugin run payload", %{
    actor: actor,
    uid: uid
  } do
    plugin_id = "scheduled-advisory-producer-#{uid}"
    agent_uid = "agent-scheduled-producer-#{uid}"

    assert {:ok, package} = create_package(actor, plugin_id)
    assert {:ok, package} = approve_package(actor, package)
    assert {:ok, assignment} = create_assignment(actor, package, agent_uid)

    {:ok, schedule} =
      ProducerSchedule
      |> Ash.Query.filter(plugin_package_id == ^package.id and schedule_id == "advisory.refresh")
      |> Ash.read_one(actor: actor)

    assert {:ok, updated} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 cadence_seconds: 21_600,
                 plugin_assignment_id: assignment.id,
                 params: %{"feed_key" => "cisa-kev"},
                 credential_refs: %{"api_token" => "cred:vulncheck"}
               },
               actor: actor
             )
             |> Ash.update()

    assert updated.contract["action_id"] == "advisory.refresh"
    assert updated.next_due_at

    payload = ProducerScheduleDispatcher.build_plugin_payload(updated, assignment)

    assert payload["schema"] == "serviceradar.producer_schedule_run.v1"
    assert payload["action_id"] == "advisory.refresh"
    assert payload["plugin_assignment_id"] == to_string(assignment.id)
    assert payload["input_values"] == %{"feed_key" => "cisa-kev"}
    assert payload["credential_refs"] == %{"api_token" => "cred:vulncheck"}
    assert payload["metadata"]["schedule_id"] == "advisory.refresh"

    transmit_payload =
      ProducerScheduleDispatcher.build_plugin_transmit_payload(payload, [
        %{
          "schema" => "serviceradar.edge_credential_broker_grant.v1",
          "grant_id" => "grant-1",
          "credential_secret_ref" => "cred:vulncheck"
        }
      ])

    refute Map.has_key?(transmit_payload, "credential_refs")

    assert transmit_payload["credential_brokers"] == [
             %{
               "schema" => "serviceradar.edge_credential_broker_grant.v1",
               "grant_id" => "grant-1",
               "credential_secret_ref" => "cred:vulncheck"
             }
           ]

    assert transmit_payload["metadata"]["credential_ref_keys"] == ["api_token"]
    assert transmit_payload["metadata"]["credential_ref_count"] == 1
    assert CredentialRedactor.redact(transmit_payload) == transmit_payload
  end

  test "one credential reference issues exact endpoint grants for token and inventory requests",
       %{
         actor: actor,
         uid: uid
       } do
    Process.put(:producer_schedule_test_pid, self())
    on_exit(fn -> Process.delete(:producer_schedule_test_pid) end)

    plugin_id = "example-inventory-producer-#{uid}"
    agent_uid = "agent-example-inventory-#{uid}"

    credential_requirements = %{
      "inventory_service_account" => %{
        "required" => true,
        "resolution_location" => "agent",
        "grants" => [
          %{
            "name" => "token",
            "grant_type" => "network_automation_oauth_password",
            "purpose" => "device_inventory_token",
            "allow" => %{"methods" => ["POST"], "url_param" => "token_url"},
            "inject" => %{
              "type" => "form_urlencoded",
              "url_param" => "token_url",
              "field_username" => "username",
              "field_password" => "password",
              "fixed_grant_type" => "password"
            }
          },
          %{
            "name" => "inventory",
            "grant_type" => "network_automation_wrapper_access",
            "purpose" => "device_inventory",
            "allow" => %{"methods" => ["POST"], "url_param" => "api_url"}
          }
        ]
      }
    }

    assert {:ok, package} =
             create_package(actor, plugin_id, %{
               "credential_requirements" => credential_requirements
             })

    assert {:ok, package} = approve_package(actor, package)
    assert {:ok, assignment} = create_assignment(actor, package, agent_uid)

    assert {:ok, schedule} =
             ProducerSchedule
             |> Ash.Query.filter(
               plugin_package_id == ^package.id and schedule_id == "advisory.refresh"
             )
             |> Ash.read_one(actor: actor)

    assert {:ok, schedule} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 plugin_assignment_id: assignment.id,
                 params: %{
                   "token_url" => "https://identity.example.com/oauth/token",
                   "api_url" => "https://wrapper.example.com/api/inventory"
                 },
                 credential_refs: %{
                   "inventory_service_account" => "credentialref:example:service-account"
                 },
                 metadata: %{"credential_rule_id" => Ash.UUID.generate()}
               },
               actor: actor
             )
             |> Ash.update()

    assert {:ok, _command_id} =
             ProducerScheduleDispatcher.dispatch(schedule,
               actor: actor,
               command_bus: __MODULE__,
               grant_issuer: fn attrs ->
                 send(test_pid(), {:inventory_credential_grant, attrs})

                 {:ok,
                  %{
                    "schema" => "serviceradar.edge_credential_broker_grant.v1",
                    "grant_id" => "grant-#{attrs.grant_type}",
                    "credential_secret_ref" => attrs.secret_ref,
                    "inject" => attrs.inject,
                    "allow" => %{
                      "methods" => attrs.allowed_methods,
                      "hosts" => attrs.allowed_hosts,
                      "ports" => attrs.allowed_ports,
                      "paths" => attrs.allowed_paths
                    }
                  }}
               end
             )

    assert_receive {:inventory_credential_grant, token_grant}
    assert token_grant.grant_type == "network_automation_oauth_password"
    assert token_grant.purpose == "device_inventory_token"
    assert token_grant.allowed_methods == ["POST"]
    assert token_grant.allowed_hosts == ["identity.example.com"]
    assert token_grant.allowed_ports == [443]
    assert token_grant.allowed_paths == ["/oauth/token"]
    assert token_grant.credential_rule_id == schedule.metadata["credential_rule_id"]

    assert token_grant.inject == %{
             "type" => "form_urlencoded",
             "method" => "POST",
             "host" => "identity.example.com",
             "path" => "/oauth/token",
             "field_username" => "username",
             "field_password" => "password",
             "fixed_grant_type" => "password"
           }

    assert_receive {:inventory_credential_grant, inventory_grant}
    assert inventory_grant.grant_type == "network_automation_wrapper_access"
    assert inventory_grant.purpose == "device_inventory"
    assert inventory_grant.allowed_methods == ["POST"]
    assert inventory_grant.allowed_hosts == ["wrapper.example.com"]
    assert inventory_grant.allowed_ports == [443]
    assert inventory_grant.allowed_paths == ["/api/inventory"]
    assert inventory_grant.credential_rule_id == schedule.metadata["credential_rule_id"]
    assert inventory_grant.inject == %{}

    assert_receive {:producer_schedule_dispatch, ^agent_uid, "plugin.run_action", payload, _opts}
    assert length(payload["credential_brokers"]) == 2
    refute Map.has_key?(payload, "credential_refs")
  end

  test "run_now records commandbus dispatch errors for offline agents", %{actor: actor, uid: uid} do
    assert {:ok, schedule} = create_enabled_schedule(actor, uid)

    assert {:ok, dispatched} =
             schedule
             |> Ash.Changeset.for_update(:run_now, %{}, actor: actor)
             |> Ash.update()

    assert dispatched.last_run_at
    assert dispatched.next_due_at
    assert dispatched.last_status == "failed"
    assert dispatched.last_error =~ "agent_offline"
  end

  test "due dispatch records status and advances next due", %{actor: actor, uid: uid} do
    assert {:ok, schedule} = create_enabled_schedule(actor, uid)
    due_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, due_schedule} =
             schedule
             |> Ash.Changeset.for_update(:update, %{next_due_at: due_at}, actor: actor)
             |> Ash.update()

    assert {:ok, dispatched} =
             due_schedule
             |> Ash.Changeset.for_update(:dispatch_due, %{}, actor: actor)
             |> Ash.update()

    assert dispatched.last_run_at
    assert DateTime.after?(dispatched.next_due_at, due_at)
    assert dispatched.last_status == "failed"
    assert dispatched.last_error =~ "agent_offline"
  end

  test "cron schedules validate cron expressions and advance from cron", %{actor: actor, uid: uid} do
    assert {:ok, schedule} = create_enabled_schedule(actor, uid)

    assert {:error, error} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{schedule_type: :cron, cron_expression: "not cron", next_due_at: nil},
               actor: actor
             )
             |> Ash.update()

    assert inspect(error) =~ "valid cron"

    assert {:ok, cron_schedule} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{schedule_type: :cron, cron_expression: "* * * * *", next_due_at: nil},
               actor: actor
             )
             |> Ash.update()

    assert cron_schedule.next_due_at
    assert DateTime.diff(cron_schedule.next_due_at, DateTime.utc_now(), :second) <= 90

    due_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, due_schedule} =
             cron_schedule
             |> Ash.Changeset.for_update(:update, %{next_due_at: due_at}, actor: actor)
             |> Ash.update()

    assert {:ok, dispatched} =
             due_schedule
             |> Ash.Changeset.for_update(:dispatch_due, %{}, actor: actor)
             |> Ash.update()

    assert DateTime.after?(dispatched.next_due_at, DateTime.utc_now())
    assert DateTime.diff(dispatched.next_due_at, DateTime.utc_now(), :second) <= 90
  end

  test "target query schedules dispatch to matching enabled plugin assignments", %{
    actor: actor,
    uid: uid
  } do
    Process.put(:producer_schedule_test_pid, self())
    Process.put(:producer_schedule_uid, uid)

    on_exit(fn ->
      Process.delete(:producer_schedule_test_pid)
      Process.delete(:producer_schedule_uid)
    end)

    plugin_id = "target-query-advisory-producer-#{uid}"

    assert {:ok, package} =
             create_package(actor, plugin_id, %{"dispatch_scope" => "target_query"})

    assert {:ok, package} = approve_package(actor, package)
    assert {:ok, _assignment_a} = create_assignment(actor, package, "agent-target-a-#{uid}")
    assert {:ok, _assignment_b} = create_assignment(actor, package, "agent-target-b-#{uid}")
    assert {:ok, _assignment_c} = create_assignment(actor, package, "agent-target-c-#{uid}")

    {:ok, schedule} =
      ProducerSchedule
      |> Ash.Query.filter(plugin_package_id == ^package.id and schedule_id == "advisory.refresh")
      |> Ash.read_one(actor: actor)

    assert {:ok, schedule} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 target_query: "in:devices tags.security_feed:true",
                 params: %{"feed_key" => "vulncheck-kev"}
               },
               actor: actor
             )
             |> Ash.update()

    assert {:ok, command_id} =
             ProducerScheduleDispatcher.dispatch(schedule,
               actor: actor,
               runner: __MODULE__,
               command_bus: __MODULE__
             )

    assert_receive {:producer_schedule_srql_query, "in:devices tags.security_feed:true"}

    assert_receive {:producer_schedule_dispatch, agent_a, "plugin.run_action", payload_a, opts_a}

    assert_receive {:producer_schedule_dispatch, agent_b, "plugin.run_action", payload_b, opts_b}

    agent_c = "agent-target-c-#{uid}"
    refute_receive {:producer_schedule_dispatch, ^agent_c, _, _, _}, 50

    assert command_id == payload_a["test_command_id"]
    assert agent_a == "agent-target-a-#{uid}"
    assert agent_b == "agent-target-b-#{uid}"
    assert payload_a["schema"] == "serviceradar.producer_schedule_run.v1"
    assert payload_a["action_id"] == "advisory.refresh"
    assert payload_a["input_values"] == %{"feed_key" => "vulncheck-kev"}
    assert payload_a["metadata"]["producer_kind"] == "wasm_plugin"
    assert payload_b["schema"] == payload_a["schema"]
    assert opts_a[:source] == :automation
    assert opts_a[:context].schedule_id == "advisory.refresh"
    assert opts_b[:context].schedule_id == "advisory.refresh"
  end

  test "package schedules dispatch to every enabled assignment for the package", %{
    actor: actor,
    uid: uid
  } do
    Process.put(:producer_schedule_test_pid, self())

    on_exit(fn -> Process.delete(:producer_schedule_test_pid) end)

    plugin_id = "package-advisory-producer-#{uid}"
    other_plugin_id = "other-package-advisory-producer-#{uid}"

    assert {:ok, package} = create_package(actor, plugin_id, %{"dispatch_scope" => "package"})
    assert {:ok, package} = approve_package(actor, package)
    assert {:ok, _assignment_a} = create_assignment(actor, package, "agent-package-a-#{uid}")
    assert {:ok, _assignment_b} = create_assignment(actor, package, "agent-package-b-#{uid}")

    assert {:ok, other_package} = create_package(actor, other_plugin_id)
    assert {:ok, other_package} = approve_package(actor, other_package)

    assert {:ok, _other_assignment} =
             create_assignment(actor, other_package, "agent-package-c-#{uid}")

    {:ok, schedule} =
      ProducerSchedule
      |> Ash.Query.filter(plugin_package_id == ^package.id and schedule_id == "advisory.refresh")
      |> Ash.read_one(actor: actor)

    assert {:ok, command_id} =
             ProducerScheduleDispatcher.dispatch(schedule,
               actor: actor,
               command_bus: __MODULE__
             )

    agent_a = "agent-package-a-#{uid}"
    agent_b = "agent-package-b-#{uid}"

    assert_receive {:producer_schedule_dispatch, ^agent_a, "plugin.run_action", payload_a,
                    _opts_a}

    assert_receive {:producer_schedule_dispatch, ^agent_b, "plugin.run_action", payload_b,
                    _opts_b}

    agent_c = "agent-package-c-#{uid}"
    refute_receive {:producer_schedule_dispatch, ^agent_c, _, _, _}, 50

    assert command_id == payload_a["test_command_id"]
    assert payload_b["schema"] == payload_a["schema"]
  end

  test "native add-on schedules dispatch through addon command path", %{actor: actor, uid: uid} do
    Process.put(:producer_schedule_test_pid, self())

    on_exit(fn -> Process.delete(:producer_schedule_test_pid) end)

    addon_id = "native-advisory-producer-#{uid}"
    agent_uid = "agent-native-producer-#{uid}"

    assert {:ok, package} = create_addon_package(actor, addon_id)
    assert {:ok, package} = approve_package(actor, package)
    assert {:ok, assignment} = create_addon_assignment(actor, package, agent_uid)

    {:ok, schedule} =
      ProducerSchedule
      |> Ash.Query.filter(addon_package_id == ^package.id and schedule_id == "advisory.refresh")
      |> Ash.read_one(actor: actor)

    assert {:ok, schedule} =
             schedule
             |> Ash.Changeset.for_update(
               :update,
               %{
                 enabled: true,
                 addon_assignment_id: assignment.id,
                 params: %{"feed_key" => "cisa-kev"},
                 credential_refs: %{"api_token" => "cred:native-feed"}
               },
               actor: actor
             )
             |> Ash.update()

    assert {:ok, command_id} =
             ProducerScheduleDispatcher.dispatch(schedule,
               actor: actor,
               command_bus: __MODULE__,
               grant_issuer: fn attrs ->
                 send(test_pid(), {:producer_schedule_credential_grant, attrs})

                 {:ok,
                  %{
                    "schema" => "serviceradar.edge_credential_broker_grant.v1",
                    "grant_id" => "grant-native",
                    "credential_secret_ref" => attrs.secret_ref
                  }}
               end
             )

    assert_receive {:producer_schedule_credential_grant, grant_attrs}
    assert grant_attrs.consumer_kind == :addon
    assert grant_attrs.consumer_id == to_string(package.id)
    assert grant_attrs.agent_id == agent_uid

    assert_receive {:producer_schedule_dispatch, ^agent_uid, "addon.run_command", payload, opts}
    assert command_id == payload["test_command_id"]
    assert payload["schema"] == "serviceradar.producer_schedule_run.v1"
    assert payload["action_id"] == "advisory.refresh"
    assert payload["addon_assignment_id"] == to_string(assignment.id)
    assert payload["addon_package_id"] == to_string(package.id)
    assert payload["addon_id"] == addon_id
    refute Map.has_key?(payload, "credential_refs")

    assert payload["credential_brokers"] == [
             %{
               "schema" => "serviceradar.edge_credential_broker_grant.v1",
               "grant_id" => "grant-native",
               "credential_secret_ref" => "cred:native-feed"
             }
           ]

    assert opts[:source] == :automation
    assert opts[:context].addon_assignment_id == to_string(assignment.id)
  end

  def query(query, _opts) do
    send(test_pid(), {:producer_schedule_srql_query, query})

    {:ok,
     [
       %{"agent_id" => matching_agent("agent-target-a")},
       %{"agent_uid" => matching_agent("agent-target-b")},
       %{"agent_id" => matching_agent("agent-target-missing-assignment")}
     ]}
  end

  def dispatch(agent_uid, command_type, payload, opts) do
    command_id = Ash.UUID.generate()
    payload = Map.put(payload, "test_command_id", command_id)

    send(test_pid(), {:producer_schedule_dispatch, agent_uid, command_type, payload, opts})

    {:ok, command_id}
  end

  defp matching_agent(prefix) do
    uid = Process.get(:producer_schedule_uid)
    "#{prefix}-#{uid}"
  end

  defp test_pid do
    Process.get(:producer_schedule_test_pid) || self()
  end

  defp create_package(actor, plugin_id, schedule_overrides \\ %{}) do
    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Advisory Producer"},
        actor: actor
      )
      |> Ash.create()

    manifest = %{
      "id" => plugin_id,
      "name" => "Advisory Producer",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => [
        "submit_result",
        "http_request",
        "artifact-staging:v1",
        "advisory-feed:v1",
        "producer-schedule:v1"
      ],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 64,
        "requested_cpu_ms" => 10_000,
        "max_open_connections" => 4
      },
      "producer_schedules" => [
        Map.merge(
          %{
            "schedule_id" => "advisory.refresh",
            "label" => "Refresh advisory feed",
            "action_id" => "advisory.refresh",
            "command_type" => "plugin.run_action",
            "allow_cron" => true,
            "default_cadence_seconds" => 86_400,
            "min_cadence_seconds" => 3_600,
            "max_cadence_seconds" => 2_592_000,
            "settings_schema" => %{"type" => "object"},
            "credential_requirements" => %{"api_token" => %{"required" => false}},
            "payload_template" => %{"producer" => "test"}
          },
          schedule_overrides
        )
      ]
    }

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Advisory Producer",
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
  end

  defp create_enabled_schedule(actor, uid) do
    plugin_id = "scheduled-dispatch-producer-#{uid}"
    agent_uid = "agent-scheduled-dispatch-#{uid}"

    with {:ok, package} <- create_package(actor, plugin_id),
         {:ok, package} <- approve_package(actor, package),
         {:ok, assignment} <- create_assignment(actor, package, agent_uid),
         {:ok, schedule} <-
           ProducerSchedule
           |> Ash.Query.filter(
             plugin_package_id == ^package.id and schedule_id == "advisory.refresh"
           )
           |> Ash.read_one(actor: actor) do
      schedule
      |> Ash.Changeset.for_update(
        :update,
        %{
          enabled: true,
          cadence_seconds: 21_600,
          plugin_assignment_id: assignment.id,
          params: %{"feed_key" => "cisa-kev"},
          credential_refs: %{"api_token" => "cred:vulncheck"}
        },
        actor: actor
      )
      |> Ash.update()
    end
  end

  defp approve_package(actor, package) do
    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
    |> Ash.update()
  end

  defp create_addon_package(actor, addon_id, schedule_overrides \\ %{}) do
    schedules = [
      Map.merge(
        %{
          "schedule_id" => "advisory.refresh",
          "label" => "Refresh native advisory feed",
          "action_id" => "advisory.refresh",
          "command_type" => "addon.run_command",
          "default_cadence_seconds" => 86_400,
          "min_cadence_seconds" => 3_600,
          "max_cadence_seconds" => 2_592_000,
          "settings_schema" => %{"type" => "object"},
          "credential_requirements" => %{"api_token" => %{"required" => false}},
          "payload_template" => %{"producer" => "native-test"}
        },
        schedule_overrides
      )
    ]

    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        addon_id: addon_id,
        name: "Native Advisory Producer",
        version: "1.0.0",
        delivery: :pushed_artifact,
        supervision: :agent_sidecar,
        binary: "serviceradar-native-advisory-producer",
        capabilities: ["advisory-feed:v1", "producer-schedule:v1"],
        config_schema: %{},
        producer_schedules: schedules,
        artifacts: %{},
        requires: %{},
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp create_addon_assignment(actor, package, agent_uid) do
    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        addon_package_id: package.id,
        source: :manual,
        enabled: true,
        params: %{}
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp create_assignment(actor, package, agent_uid) do
    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        plugin_package_id: package.id,
        source: :manual,
        enabled: true,
        interval_seconds: 3_600,
        timeout_seconds: 600,
        params: %{}
      },
      actor: actor
    )
    |> Ash.create()
  end
end
