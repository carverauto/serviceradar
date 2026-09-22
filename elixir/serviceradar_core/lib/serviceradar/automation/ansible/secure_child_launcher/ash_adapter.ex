defmodule ServiceRadar.Automation.Ansible.SecureChildLauncher.AshAdapter do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.SecureChildLauncher.Adapter

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User

  @actor SystemActor.system(:ansible_secure_child_launcher)

  @impl true
  def load_current_actor(actor_id) do
    actor_id
    |> User.get_by_id(actor: @actor)
    |> required(:actor_not_found)
  end

  @impl true
  def fresh_authorization(%User{} = actor) do
    case RBAC.effective_authority(actor, @actor) do
      {:ok, %{permissions: %MapSet{} = permissions, profile_versions: profile_versions}} ->
        {:ok, %{permissions: permissions, profile_versions: profile_versions}}

      {:error, reason} ->
        {:error, {:fresh_authorization_failed, reason}}
    end
  rescue
    error -> {:error, {:fresh_authorization_failed, error}}
  end

  def fresh_authorization(_actor), do: {:error, :fresh_authorization_required}

  @impl true
  def load_playbook(playbook_id) do
    playbook_id
    |> Playbook.get_by_id(actor: @actor)
    |> required(:playbook_not_found)
  end

  @impl true
  def load_memberships(membership_ids) do
    membership_ids
    |> Enum.reduce_while({:ok, []}, fn membership_id, {:ok, memberships} ->
      case AwxHostMembership.get_by_id(membership_id, actor: @actor) do
        {:ok, nil} -> {:halt, {:error, {:membership_not_found, membership_id}}}
        {:ok, membership} -> {:cont, {:ok, [membership | memberships]}}
        {:error, reason} -> {:halt, {:error, {:membership_lookup_failed, reason}}}
      end
    end)
    |> case do
      {:ok, memberships} -> {:ok, Enum.reverse(memberships)}
      error -> error
    end
  end

  @impl true
  def load_binding(controller_id, job_template_id) do
    controller_id
    |> AwxTemplateBinding.get_current_for_template(job_template_id, actor: @actor)
    |> required(:binding_not_found)
  end

  @impl true
  def load_controller(controller_id) do
    controller_id
    |> Controller.get_by_id(actor: @actor)
    |> required(:controller_not_found)
  end

  @impl true
  def active_hold_device_uids(device_uids) do
    device_uids
    |> Enum.reduce_while({:ok, []}, fn device_uid, {:ok, held} ->
      case AutomationTargetHold.get_active_for_device(device_uid,
             actor: @actor,
             not_found_error?: false
           ) do
        {:ok, nil} ->
          {:cont, {:ok, held}}

        {:ok, hold} ->
          {:cont, {:ok, [hold.canonical_device_uid | held]}}

        {:error, reason} ->
          if ash_not_found?(reason) do
            {:cont, {:ok, held}}
          else
            {:halt, {:error, {:target_hold_lookup_failed, reason}}}
          end
      end
    end)
    |> case do
      {:ok, held} -> {:ok, held |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  @impl true
  def launch(plan, controller), do: HardenedRunLauncher.launch(plan, controller)

  # Only a pure NotFound is "device not held". Mixed Ash error classes that
  # include NotFound alongside other failures must fail closed.
  defp ash_not_found?(%Ash.Error.Query.NotFound{}), do: true

  defp ash_not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) and errors != [] do
    Enum.all?(errors, &ash_not_found?/1)
  end

  defp ash_not_found?(%Ash.Error.Unknown{errors: errors}) when is_list(errors) and errors != [] do
    Enum.all?(errors, &ash_not_found?/1)
  end

  defp ash_not_found?(_), do: false

  defp required({:ok, nil}, error), do: {:error, error}
  defp required({:ok, value}, _error), do: {:ok, value}
  defp required({:error, reason}, _error), do: {:error, reason}
end
