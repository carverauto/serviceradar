defmodule ServiceRadar.Automation.Northbound.Catalog do
  @moduledoc """
  Eligibility helpers for provider-neutral northbound actions.

  The first implementation exposes configured northbound descriptors and keeps
  the existing Ansible launch path as a first-party adapter when launchable AWX
  playbooks exist. That keeps the UI generic while Ansible is migrated behind
  the shared invocation model.
  """

  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Northbound.ActionDescriptor

  require Ash.Query

  @type action_summary :: %{
          id: String.t(),
          label: String.t(),
          provider_type: String.t(),
          scope: String.t(),
          destination: String.t() | nil
        }

  @spec eligible_device_actions(term()) :: [action_summary()]
  def eligible_device_actions(scope) do
    descriptor_actions(scope, "device") ++ ansible_device_actions(scope)
  end

  @spec launchable_device_actions?(term()) :: boolean()
  def launchable_device_actions?(scope), do: eligible_device_actions(scope) != []

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
      label: descriptor.label,
      provider_type: to_string(provider.provider_type),
      scope: action_scope,
      destination: nil
    }
  end

  defp ansible_device_actions(scope) do
    if launchable_ansible_playbook_count(scope) > 0 do
      [
        %{
          id: "ansible:run_playbook",
          label: "Run Ansible Playbook",
          provider_type: "ansible",
          scope: "device",
          destination: "/ansible/launch"
        }
      ]
    else
      []
    end
  end

  defp launchable_ansible_playbook_count(scope) do
    Playbook
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(not is_nil(awx_job_template_id))
    |> Ash.count(scope: scope)
    |> case do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  rescue
    _ -> 0
  end
end
