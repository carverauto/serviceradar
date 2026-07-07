defmodule ServiceRadar.Automation.Northbound.Catalog do
  @moduledoc """
  Eligibility helpers for provider-neutral northbound actions.

  The first implementation exposes configured northbound descriptors and keeps
  the existing Ansible launch path as a first-party adapter when launchable AWX
  playbooks exist. That keeps the UI generic while Ansible is migrated behind
  the shared invocation model.
  """

  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.AnsibleActionSync

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
    _ = AnsibleActionSync.sync_launchable_playbooks()

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
    |> Ash.Query.for_read(:enabled_for_scope, %{scope: action_scope})
    |> Ash.Query.load(:provider)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, descriptors} ->
        descriptors
        |> Enum.filter(&provider_launchable?/1)
        |> Enum.map(&descriptor_summary(&1, action_scope))

      {:error, _reason} ->
        []
    end
  end

  defp provider_launchable?(%{provider: %{status: :active}}), do: true
  defp provider_launchable?(%{provider: %Ash.NotLoaded{}}), do: false
  defp provider_launchable?(_descriptor), do: false

  defp descriptor_summary(descriptor, action_scope) do
    provider = descriptor.provider

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
      # Provider-specific descriptor metadata. For AWX/Ansible descriptors this
      # carries "playbook_id"/"source_type", which the Run Task modal uses to
      # render a typed variable form (VariableSchema.from_playbook/1).
      metadata: descriptor.metadata || %{}
    }
  end
end
