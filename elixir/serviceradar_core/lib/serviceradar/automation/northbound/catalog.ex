defmodule ServiceRadar.Automation.Northbound.Catalog do
  @moduledoc """
  Eligibility helpers for provider-neutral northbound actions.

  The operator catalog exposes configured, active northbound descriptors.
  Retained Ansible providers are an internal compatibility surface and are
  never synchronized or exposed by this read path.
  """

  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider

  require Ash.Query

  @type action_summary :: %{
          id: String.t(),
          descriptor_id: String.t() | nil,
          label: String.t(),
          description: String.t() | nil,
          provider_type: String.t(),
          provider_name: String.t() | nil,
          scope: String.t(),
          destination: String.t() | nil,
          input_schema: map(),
          safety_classification: String.t(),
          requires_confirmation: boolean(),
          timeout_seconds: pos_integer(),
          metadata: map()
        }

  @spec eligible_device_actions(term()) :: [action_summary()]
  def eligible_device_actions(scope) do
    descriptor_actions(scope, "device")
  end

  @spec eligible_interface_actions(term()) :: [action_summary()]
  def eligible_interface_actions(scope) do
    descriptor_actions(scope, "interface")
  end

  @spec launchable_device_actions?(term()) :: boolean()
  def launchable_device_actions?(scope), do: eligible_device_actions(scope) != []

  @spec launchable_interface_actions?(term()) :: boolean()
  def launchable_interface_actions?(scope), do: eligible_interface_actions(scope) != []

  defp descriptor_actions(scope, action_scope) do
    ActionDescriptor
    |> Ash.Query.for_read(:launchable_for_scope, %{scope: action_scope})
    |> Ash.read(scope: scope)
    |> case do
      {:ok, descriptors} ->
        descriptor_actions_with_providers(descriptors, scope, action_scope)

      {:error, _reason} ->
        []
    end
  end

  defp descriptor_actions_with_providers([], _scope, _action_scope), do: []

  defp descriptor_actions_with_providers(descriptors, scope, action_scope) do
    provider_ids = descriptors |> Enum.map(& &1.provider_id) |> Enum.uniq()

    case ActionProvider.list_launch_candidates_by_ids(provider_ids, scope: scope) do
      {:ok, providers} ->
        providers_by_id = Map.new(providers, &{&1.id, &1})

        Enum.flat_map(descriptors, fn descriptor ->
          case Map.get(providers_by_id, descriptor.provider_id) do
            nil -> []
            provider -> [descriptor_summary(descriptor, provider, action_scope)]
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp descriptor_summary(descriptor, provider, action_scope) do
    %{
      id: "northbound:#{descriptor.id}",
      descriptor_id: descriptor.id,
      label: descriptor.label,
      description: descriptor.description,
      provider_type: to_string(provider.provider_type),
      provider_name: provider.name,
      scope: action_scope,
      destination: nil,
      input_schema: descriptor.input_schema || %{},
      safety_classification: to_string(descriptor.safety_classification),
      requires_confirmation: descriptor.requires_confirmation,
      timeout_seconds: descriptor.timeout_seconds,
      # Provider-specific descriptor metadata used by the provider-neutral
      # invocation and dispatch paths.
      metadata: descriptor.metadata || %{}
    }
  end
end
