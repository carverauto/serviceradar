defmodule ServiceRadar.Automation.Northbound.CatalogTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.Catalog
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    admin_actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-catalog-test@serviceradar.local",
      role: :admin
    }

    launch_actor = %{
      id: Ash.UUID.generate(),
      email: "northbound-launch-only@serviceradar.local",
      role: :viewer,
      permissions: MapSet.new(["northbound.actions.launch"])
    }

    {:ok, actor: admin_actor, launch_actor: launch_actor, launch_scope: %{actor: launch_actor}}
  end

  test "launch-only catalog exposes non-Ansible candidates without granting general reads", %{
    actor: actor,
    launch_actor: launch_actor,
    launch_scope: launch_scope
  } do
    {_native_provider, native_descriptor} = create_action(actor, :native, enabled: true)
    {_wasm_provider, wasm_descriptor} = create_action(actor, :wasm_plugin, enabled: true)
    {_ansible_provider, ansible_descriptor} = create_action(actor, :ansible, enabled: true)

    {disabled_ansible_provider, disabled_ansible_descriptor} =
      create_action(actor, :ansible, provider_status: :disabled, enabled: false)

    actions = Catalog.eligible_device_actions(launch_scope)

    assert MapSet.new(actions, & &1.descriptor_id) ==
             MapSet.new([native_descriptor.id, wasm_descriptor.id])

    refute Enum.any?(actions, &(&1.descriptor_id == ansible_descriptor.id))

    assert {:error, _reason} =
             ActionDescriptor.get_by_id(native_descriptor.id, actor: launch_actor)

    assert {:error, _reason} =
             ActionProvider.get_by_id(disabled_ansible_provider.id, actor: launch_actor)

    assert {:ok, reloaded_provider} =
             ActionProvider.get_by_id(disabled_ansible_provider.id, actor: actor)

    assert {:ok, reloaded_descriptor} =
             ActionDescriptor.get_by_id(disabled_ansible_descriptor.id, actor: actor)

    assert reloaded_provider.status == :disabled
    refute reloaded_descriptor.enabled
  end

  defp create_action(actor, provider_type, opts) do
    unique = System.unique_integer([:positive])

    {:ok, provider} =
      ActionProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{provider_type} provider #{unique}",
          provider_type: provider_type,
          source_ref: "test:catalog:#{provider_type}:#{unique}",
          approved_capabilities: [],
          credential_requirements: %{},
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    provider = transition_provider(provider, Keyword.get(opts, :provider_status, :active), actor)

    {:ok, descriptor} =
      ActionDescriptor
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider_id: provider.id,
          action_id: "test.catalog.#{provider_type}.#{unique}",
          version: "1.0.0",
          label: "#{provider_type} catalog action",
          scopes: ["device"],
          required_context: ["device.uid"],
          input_schema: %{},
          safety_classification: :standard,
          requires_confirmation: false,
          timeout_seconds: 60,
          credential_requirements: %{},
          result_schema_version: "serviceradar.northbound_action_result.v1",
          descriptor_hash: "catalog-#{unique}",
          enabled: Keyword.fetch!(opts, :enabled),
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor, domain: Northbound)

    {provider, descriptor}
  end

  defp transition_provider(provider, :active, actor) do
    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
      |> Ash.update(actor: actor, domain: Northbound)

    provider
  end

  defp transition_provider(provider, :disabled, actor) do
    {:ok, provider} =
      provider
      |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
      |> Ash.update(actor: actor, domain: Northbound)

    provider
  end
end
