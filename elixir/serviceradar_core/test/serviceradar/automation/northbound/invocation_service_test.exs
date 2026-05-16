defmodule ServiceRadar.Automation.Northbound.InvocationServiceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Inventory.Device
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
    assert [%{"kind" => "device", "device_uid" => device_uid}] = invocation.target_snapshots
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
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        name: "test-device",
        hostname: "test-device",
        ip: "192.0.2.10",
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
end
