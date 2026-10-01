defmodule ServiceRadar.Automation.Northbound.CatalogTest do
  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.Catalog
  alias ServiceRadar.TestSupport

  @moduletag :integration

  defmodule FakeErrorContext do
    @moduledoc false
    def rule_options(_descriptor, _provider, _opts \\ []), do: {:error, :test_db_error}
  end

  defmodule EmptyRulesContext do
    @moduledoc false
    def rule_options(_descriptor, _provider, _opts \\ []),
      do: {:ok, %{"destination_rule_id" => []}}
  end

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

  test "rule_options error: action still appears with x-credential-rule-options-error on package_rule inputs",
       %{launch_scope: launch_scope, actor: actor} do
    {_provider, descriptor} =
      create_action(actor, :wasm_plugin,
        enabled: true,
        credential_requirements: %{
          "destination_rule_id" => %{
            "credential_source" => "package_rule",
            "rule_input" => "destination_rule_id"
          }
        },
        input_schema: %{"properties" => %{"destination_rule_id" => %{"type" => "string"}}}
      )

    log =
      capture_log(fn ->
        actions =
          Catalog.eligible_device_actions(launch_scope, plugin_package_context: FakeErrorContext)

        action = Enum.find(actions, &(&1.descriptor_id == descriptor.id))
        assert action, "action should still appear when rule_options fails"

        property = action.input_schema["properties"]["destination_rule_id"]
        assert property["x-credential-rule-options-error"] == true
        refute Map.has_key?(property, "enum")
        refute Map.has_key?(property, "x-credential-rule-options")
      end)

    assert log =~ inspect(:test_db_error)
  end

  test "successful empty rule lookup emits an explicit empty choice", %{actor: actor} do
    {_provider, descriptor} =
      create_action(actor, :wasm_plugin,
        enabled: true,
        credential_requirements: %{
          "destination_rule_id" => %{
            "credential_source" => "package_rule",
            "rule_input" => "destination_rule_id"
          }
        },
        input_schema: %{"properties" => %{"destination_rule_id" => %{"type" => "string"}}}
      )

    [action] =
      Catalog.eligible_device_actions(%{actor: actor}, plugin_package_context: EmptyRulesContext)
      |> Enum.filter(&(&1.descriptor_id == descriptor.id))

    property = action.input_schema["properties"]["destination_rule_id"]
    assert property["enum"] == []
    assert property["x-credential-rule-options-empty"] == true
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
          input_schema: Keyword.get(opts, :input_schema, %{}),
          safety_classification: :standard,
          requires_confirmation: false,
          timeout_seconds: 60,
          credential_requirements: Keyword.get(opts, :credential_requirements, %{}),
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
