defmodule ServiceRadar.Automation.Northbound.HistoryTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.History
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-history-test@serviceradar.local",
      role: :admin
    }

    {:ok,
     actor: actor,
     device_uid: "sr:history-#{System.unique_integer([:positive])}",
     interface_uid: "ifindex:#{System.unique_integer([:positive])}"}
  end

  test "operator filtering excludes Ansible before device and interface limits", %{
    actor: actor,
    device_uid: device_uid,
    interface_uid: interface_uid
  } do
    create_history(actor, :native, device_uid, interface_uid)
    create_history(actor, :ansible, device_uid, interface_uid)

    assert {:ok, default_device_history} =
             History.list_for_device(device_uid, actor: actor, limit: 10)

    assert MapSet.new(default_device_history, & &1.provider_type) ==
             MapSet.new(["native", "ansible"])

    assert {:ok, [%{provider_type: "native"}]} =
             History.list_for_device(device_uid,
               actor: actor,
               limit: 1,
               exclude_provider_types: [:ansible]
             )

    assert {:ok, default_interface_history} =
             History.list_for_interface(device_uid, interface_uid, actor: actor, limit: 10)

    assert MapSet.new(default_interface_history, & &1.provider_type) ==
             MapSet.new(["native", "ansible"])

    assert {:ok, [%{provider_type: "native"}]} =
             History.list_for_interface(device_uid, interface_uid,
               actor: actor,
               limit: 1,
               exclude_provider_types: [:ansible]
             )
  end

  test "operator filtering retains the immutable provider snapshot after provider deletion", %{
    actor: actor,
    device_uid: device_uid,
    interface_uid: interface_uid
  } do
    create_history(actor, :native, device_uid, interface_uid)
    %{provider: ansible_provider} = create_history(actor, :ansible, device_uid, interface_uid)

    assert :ok = Ash.destroy(ansible_provider, actor: actor, domain: Northbound)

    assert {:ok, default_device_history} =
             History.list_for_device(device_uid, actor: actor, limit: 10)

    assert MapSet.new(default_device_history, & &1.provider_type) ==
             MapSet.new(["native", "ansible"])

    assert {:ok, [%{provider_type: "native"}]} =
             History.list_for_device(device_uid,
               actor: actor,
               limit: 1,
               exclude_provider_types: [:ansible]
             )

    assert {:ok, [%{provider_type: "native"}]} =
             History.list_for_interface(device_uid, interface_uid,
               actor: actor,
               limit: 1,
               exclude_provider_types: [:ansible]
             )
  end

  defp create_history(actor, provider_type, device_uid, interface_uid) do
    unique = System.unique_integer([:positive])

    {:ok, provider} =
      ActionProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{provider_type} history provider #{unique}",
          provider_type: provider_type,
          source_ref: "test:history:#{provider_type}:#{unique}",
          approved_capabilities: [],
          credential_requirements: %{},
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
      |> Ash.update(actor: actor, domain: Northbound)

    {:ok, descriptor} =
      ActionDescriptor
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider_id: provider.id,
          action_id: "test.history.#{provider_type}.#{unique}",
          version: "1.0.0",
          label: "#{provider_type} history action",
          scopes: ["device", "interface"],
          required_context: ["device.uid"],
          input_schema: %{},
          safety_classification: :standard,
          requires_confirmation: false,
          timeout_seconds: 60,
          credential_requirements: %{},
          result_schema_version: "serviceradar.northbound_action_result.v1",
          descriptor_hash: "history-#{unique}",
          enabled: true,
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    {:ok, invocation} =
      ActionInvocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          descriptor_id: descriptor.id,
          action_id: descriptor.action_id,
          action_version: descriptor.version,
          descriptor_hash: descriptor.descriptor_hash,
          source: :user,
          requested_by_actor_id: actor.id,
          target_snapshots: [
            %{"kind" => "device", "device_uid" => device_uid},
            %{
              "kind" => "interface",
              "device_uid" => device_uid,
              "interface_uid" => interface_uid
            }
          ],
          input_values: %{},
          metadata: %{"provider_type" => to_string(provider_type)}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    create_target(actor, invocation, :device, device_uid, nil)
    create_target(actor, invocation, :interface, device_uid, interface_uid)

    %{provider: provider, descriptor: descriptor, invocation: invocation}
  end

  defp create_target(actor, invocation, target_kind, device_uid, interface_uid) do
    {:ok, _target} =
      ActionInvocationTarget
      |> Ash.Changeset.for_create(
        :create,
        %{
          invocation_id: invocation.id,
          target_kind: target_kind,
          device_uid: device_uid,
          interface_uid: interface_uid,
          target_snapshot: %{
            "kind" => to_string(target_kind),
            "device_uid" => device_uid,
            "interface_uid" => interface_uid
          },
          status: :pending,
          result: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    :ok
  end
end
