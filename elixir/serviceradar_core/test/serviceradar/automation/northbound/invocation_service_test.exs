defmodule ServiceRadar.Automation.Northbound.InvocationServiceTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: Ash.UUID.generate(), email: "northbound-test@serviceradar.local", role: :admin}
    {:ok, actor: actor}
  end

  test "creates an invocation with redacted inputs and target rows", %{actor: actor} do
    {:ok, provider} = create_provider(actor)
    {:ok, descriptor} = create_descriptor(provider, actor)
    {:ok, device} = create_device(actor)

    assert {:ok, invocation} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [%{kind: :device, device_uid: device.uid}],
                 input_values: %{"command" => "show version", "password" => "secret"}
               },
               actor: actor
             )

    assert invocation.provider_id == provider.id
    assert invocation.descriptor_id == descriptor.id
    assert invocation.action_id == descriptor.action_id
    assert invocation.state == :pending

    assert invocation.redacted_input_values == %{
             "command" => "show version",
             "password" => "[REDACTED]"
           }

    assert invocation.metadata["input_sha256"]
    assert [%{target_kind: :device, device_uid: device_uid}] = invocation.targets
    assert device_uid == device.uid
    assert [%{"kind" => "device", "device_uid" => ^device_uid}] = invocation.target_snapshots
  end

  test "launch permission can create invocation target rows without admin role", %{actor: actor} do
    {:ok, provider} = create_provider(actor)
    {:ok, descriptor} = create_descriptor(provider, actor)
    {:ok, device} = create_device(actor)

    launch_actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-launcher@serviceradar.local",
      role: :viewer,
      permissions: MapSet.new(["northbound.actions.launch"])
    }

    assert {:ok, invocation} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [%{kind: :device, device_uid: device.uid}],
                 input_values: %{"reason" => "operator requested audit"}
               },
               actor: launch_actor
             )

    assert [%{target_kind: :device, device_uid: device_uid}] = invocation.targets
    assert device_uid == device.uid
  end

  test "launch-only actors cannot submit package credential rule inputs", %{actor: actor} do
    package = create_plugin_package(["example-sat"])

    {:ok, provider} =
      create_provider(actor, provider_type: :wasm_plugin, plugin_package_id: package.id)

    requirements = %{
      "destination_account" => %{
        "credential_source" => "package_rule",
        "rule_input" => "destination_rule_id",
        "required" => true
      }
    }

    {:ok, descriptor} = create_descriptor(provider, actor, credential_requirements: requirements)
    {:ok, device} = create_device(actor)

    launch_actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-launcher@example.com",
      role: :viewer,
      permissions: MapSet.new(["northbound.actions.launch"])
    }

    assert {:error, :credential_rule_permission_required} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [%{kind: :device, device_uid: device.uid}],
                 input_values: %{"destination_rule_id" => "synthetic-rule-id"}
               },
               actor: launch_actor
             )
  end

  test "rejects inactive providers", %{actor: actor} do
    {:ok, provider} = create_provider(actor, activate?: false)
    {:ok, descriptor} = create_descriptor(provider, actor)
    {:ok, device} = create_device(actor)

    assert {:error, {:provider_not_active, :staged}} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [%{kind: :device, device_uid: device.uid}],
                 input_values: %{}
               },
               actor: actor
             )
  end

  test "rejects targets outside the descriptor scopes before resolving inventory", %{actor: actor} do
    {:ok, provider} = create_provider(actor)
    {:ok, descriptor} = create_descriptor(provider, actor, scopes: ["device"])

    assert {:error, {:unsupported_target_scope, "interface"}} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [
                   %{
                     kind: :interface,
                     device_uid: "sr:missing-device",
                     interface_uid: "if-1"
                   }
                 ],
                 input_values: %{}
               },
               actor: actor
             )
  end

  test "normalizes interface status IDs for action target snapshots", %{actor: actor} do
    {:ok, provider} = create_provider(actor)
    {:ok, descriptor} = create_descriptor(provider, actor, scopes: ["interface"])
    {:ok, device} = create_device(actor)
    {:ok, interface} = create_interface(actor, device)

    assert {:ok, invocation} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [
                   %{
                     kind: :interface,
                     device_uid: device.uid,
                     interface_uid: interface.interface_uid
                   }
                 ],
                 input_values: %{}
               },
               actor: actor
             )

    assert [
             %{
               "if_index" => 17,
               "ifIndex" => 17,
               "ifindex" => 17,
               "if_name" => "Gi1/0/17",
               "interface_name" => "Gi1/0/17",
               "physical_path" => "1/0/17",
               "stack_member" => "1",
               "module" => "0",
               "slot" => "0",
               "port" => "17",
               "physical_context" => %{
                 "name" => "Gi1/0/17",
                 "path" => "1/0/17",
                 "stack_member" => "1",
                 "module" => "0",
                 "slot" => "0",
                 "port" => "17"
               },
               "if_admin_status" => "up",
               "if_admin_status_id" => 1,
               "if_oper_status" => "down",
               "if_oper_status_id" => 2
             }
           ] = invocation.target_snapshots
  end

  test "plugin action snapshots carry only the package's own integration ids", %{actor: actor} do
    package = create_plugin_package(["example-sat", "example-sat-router"])

    {:ok, provider} =
      create_provider(actor, provider_type: :wasm_plugin, plugin_package_id: package.id)

    {:ok, descriptor} = create_descriptor(provider, actor, scopes: ["device", "interface"])
    {:ok, device} = create_device(actor)
    {:ok, interface} = create_interface(actor, device)

    register_identifiers(device, [
      {:integration_id, "example-sat:ut:ut-0002"},
      {:integration_id, "example-sat:ut:ut-0001"},
      {:integration_id, "example-sat-router:rt-0003"},
      {:integration_id, "other-source:dev-0004"},
      {:integration_id, "example-satx:ut-0005"},
      {:integration_id, "example-sat:"},
      {:mac, "00005E005301"}
    ])

    assert {:ok, invocation} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [
                   %{kind: :device, device_uid: device.uid},
                   %{
                     kind: :interface,
                     device_uid: device.uid,
                     interface_uid: interface.interface_uid
                   }
                 ],
                 input_values: %{}
               },
               actor: actor
             )

    expected = ["example-sat-router:rt-0003", "example-sat:ut:ut-0001", "example-sat:ut:ut-0002"]

    assert [
             %{"kind" => "device", "attributes" => %{"integration_ids" => ^expected}},
             %{"kind" => "interface", "attributes" => %{"integration_ids" => ^expected}}
           ] = invocation.target_snapshots
  end

  test "non-plugin action snapshots are unchanged by integration identifiers", %{actor: actor} do
    {:ok, provider} = create_provider(actor)
    {:ok, descriptor} = create_descriptor(provider, actor)
    {:ok, device} = create_device(actor)
    register_identifiers(device, [{:integration_id, "example-sat:ut:ut-0001"}])

    assert {:ok, invocation} =
             InvocationService.create_invocation(
               %{
                 descriptor_id: descriptor.id,
                 targets: [%{kind: :device, device_uid: device.uid}],
                 input_values: %{}
               },
               actor: actor
             )

    assert [snapshot] = invocation.target_snapshots
    refute Map.has_key?(snapshot, "attributes")

    assert snapshot |> Map.keys() |> Enum.sort() ==
             ~w(agent_id device_uid discovery_sources gateway_id hostname ip is_available kind mac model name type vendor_name)
  end

  defp create_plugin_package(sources) do
    actor = SystemActor.system(:northbound_invocation_service_test)
    plugin_id = "example-sat-#{System.unique_integer([:positive])}"

    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Satellite"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    manifest = %{
      "id" => plugin_id,
      "name" => "Example Satellite",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 1_000,
        "max_open_connections" => 1
      },
      "integrations" => %{
        "inventory_sources" =>
          Enum.map(sources, &%{"source" => &1, "label" => "Example source #{&1}"})
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
          content_hash: "sha256:#{plugin_id}-1.0.0",
          source_type: :upload
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> Ash.update(actor: actor)

    package
  end

  defp register_identifiers(device, identifiers) do
    actor = SystemActor.system(:northbound_invocation_service_test)

    Enum.each(identifiers, fn {type, value} ->
      {:ok, _identifier} =
        DeviceIdentifier
        |> Ash.Changeset.for_create(
          :register,
          %{
            device_id: device.uid,
            identifier_type: type,
            identifier_value: value,
            partition: "default",
            confidence: :strong,
            source: "test"
          },
          actor: actor
        )
        |> Ash.create(actor: actor, domain: ServiceRadar.Inventory)
    end)
  end

  defp create_provider(actor, opts \\ []) do
    source_ref = "test:#{System.unique_integer([:positive])}"

    with {:ok, provider} <-
           ActionProvider
           |> Ash.Changeset.for_create(
             :create,
             %{
               name: "Test Provider",
               provider_type: Keyword.get(opts, :provider_type, :native),
               plugin_package_id: Keyword.get(opts, :plugin_package_id),
               source_ref: source_ref,
               approved_capabilities: [],
               credential_requirements: %{},
               metadata: %{}
             },
             actor: actor
           )
           |> Ash.create(actor: actor, domain: Northbound) do
      if Keyword.get(opts, :activate?, true) do
        provider
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update(actor: actor, domain: Northbound)
      else
        {:ok, provider}
      end
    end
  end

  defp create_descriptor(provider, actor, opts \\ []) do
    ActionDescriptor
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        provider_id: provider.id,
        action_id: "test.run",
        version: "1.0.0",
        label: "Run Test",
        scopes: Keyword.get(opts, :scopes, ["device"]),
        required_context: ["device.ip"],
        input_schema: %{},
        safety_classification: :standard,
        requires_confirmation: false,
        timeout_seconds: 60,
        credential_requirements: Keyword.get(opts, :credential_requirements, %{}),
        result_schema_version: "serviceradar.northbound_action_result.v1",
        descriptor_hash: "test",
        enabled: true,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor, domain: Northbound)
  end

  defp create_device(actor) do
    uid = "sr:test-#{System.unique_integer([:positive])}"
    host_octet = rem(System.unique_integer([:positive]), 200) + 20
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        name: "test-device",
        hostname: "test-device",
        ip: "192.0.2.#{host_octet}",
        type_id: 0,
        created_time: now,
        modified_time: now,
        discovery_sources: ["test"],
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor, domain: ServiceRadar.Inventory)
  end

  defp create_interface(actor, device) do
    Interface
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: DateTime.truncate(DateTime.utc_now(), :second),
        device_id: device.uid,
        interface_uid: "ifindex:#{System.unique_integer([:positive])}",
        if_index: 17,
        device_ip: device.ip,
        if_name: "Gi1/0/17",
        if_descr: "GigabitEthernet1/0/17",
        if_admin_status: 1,
        if_oper_status: 2,
        if_type_name: "ethernetCsmacd",
        interface_kind: "physical",
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create(actor: actor, domain: ServiceRadar.Inventory)
  end
end
