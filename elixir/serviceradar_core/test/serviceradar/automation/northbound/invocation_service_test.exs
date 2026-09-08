defmodule ServiceRadar.Automation.Northbound.InvocationServiceTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
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

  defp create_provider(actor, opts \\ []) do
    source_ref = "test:#{System.unique_integer([:positive])}"

    with {:ok, provider} <-
           ActionProvider
           |> Ash.Changeset.for_create(
             :create,
             %{
               name: "Test Provider",
               provider_type: :native,
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
        credential_requirements: %{},
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
