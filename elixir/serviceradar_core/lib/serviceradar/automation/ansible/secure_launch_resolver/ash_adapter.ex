defmodule ServiceRadar.Automation.Ansible.SecureLaunchResolver.AshAdapter do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.SecureLaunchResolver.Adapter

  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Playbook

  @impl true
  def load_playbook(playbook_id, actor) do
    playbook_id
    |> Playbook.get_launch_candidate_by_id(actor: actor)
    |> required(:playbook_not_found)
  end

  @impl true
  def list_current_memberships(device_uid, actor) do
    case AwxHostMembership.list_current_for_device(device_uid, actor: actor) do
      {:ok, memberships} when is_list(memberships) -> {:ok, memberships}
      {:ok, _other} -> {:error, :membership_lookup_failed}
      {:error, reason} -> {:error, {:membership_lookup_failed, reason}}
    end
  end

  @impl true
  def load_current_approved_binding(controller_id, job_template_id, actor) do
    controller_id
    |> AwxTemplateBinding.get_current_approved_for_template(job_template_id, actor: actor)
    |> required(:binding_not_approved)
  end

  defp required({:ok, nil}, error), do: {:error, error}
  defp required({:ok, value}, _error), do: {:ok, value}
  defp required({:error, reason}, _error), do: {:error, reason}
end
