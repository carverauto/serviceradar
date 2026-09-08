defmodule ServiceRadar.Automation.CallbackGrants.CurrentAuthorityAshSource do
  @moduledoc """
  Fresh Ash-backed reads for callback authorization.

  The system actor in this module is a persistence-policy actor only. Its role
  and permissions are never returned as callback authority; authority is
  reconstructed from the grant's initiating human or owned service principal.
  """

  @behaviour ServiceRadar.Automation.CallbackGrants.CurrentAuthoritySource

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User

  @actor SystemActor.system(:automation_callback_current_authority_store)

  @impl true
  def load_principal(:human, principal_id, _owner_id) do
    with {:ok, %User{} = user} <- required(User.get_by_id(principal_id, actor: @actor)),
         {:ok, authority} <- effective_authority(user) do
      {:ok, %{principal: user, owner: user, authority: authority}}
    end
  end

  def load_principal(:service_principal, principal_id, owner_id) do
    with {:ok, %OAuthClient{} = client} <-
           required(OAuthClient.get_by_id(principal_id, actor: @actor)),
         true <-
           to_string(client.user_id) == to_string(owner_id) || {:error, :principal_owner_changed},
         {:ok, %User{} = owner} <- required(User.get_by_id(client.user_id, actor: @actor)),
         {:ok, authority} <- effective_authority(owner) do
      {:ok, %{principal: client, owner: owner, authority: authority}}
    else
      false -> {:error, :principal_owner_changed}
      {:error, _} = error -> error
    end
  end

  def load_principal(_type, _principal_id, _owner_id), do: {:error, :principal_not_found}

  @impl true
  def load_operation(id), do: required(AutomationOperation.get_by_id(id, actor: @actor))

  @impl true
  def load_execution(id), do: required(AutomationExecution.get_by_id(id, actor: @actor))

  @impl true
  def load_execution_targets(execution_id) do
    case AutomationExecutionTarget.list_for_execution(execution_id, actor: @actor) do
      {:ok, targets} when is_list(targets) -> {:ok, targets}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :execution_targets_unavailable}
    end
  end

  @impl true
  def load_memberships(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, memberships} ->
      case required(AwxHostMembership.get_by_id(id, actor: @actor)) do
        {:ok, membership} -> {:cont, {:ok, [membership | memberships]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, memberships} -> {:ok, Enum.reverse(memberships)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def load_current_binding(controller_id, job_template_id) do
    required(
      AwxTemplateBinding.get_current_for_template(controller_id, job_template_id, actor: @actor)
    )
  end

  @impl true
  def active_holds(device_uids) when is_list(device_uids) do
    Enum.reduce_while(device_uids, {:ok, []}, fn device_uid, {:ok, holds} ->
      case AutomationTargetHold.get_active_for_device(device_uid,
             actor: @actor,
             not_found_error?: false
           ) do
        {:ok, nil} ->
          {:cont, {:ok, holds}}

        {:ok, hold} ->
          {:cont, {:ok, [hold | holds]}}

        {:error, reason} ->
          if ash_not_found?(reason) do
            {:cont, {:ok, holds}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
  end

  @impl true
  def callback_credential_contract do
    config =
      Application.get_env(
        :serviceradar_core,
        :automation_callback_awx_credential_contract,
        []
      )

    type_id = Keyword.get(config, :credential_type_id)
    organization_id = Keyword.get(config, :organization_id)
    injector_digest = Keyword.get(config, :injector_digest)

    if positive_integer?(type_id) and positive_integer?(organization_id) and
         digest?(injector_digest) do
      {:ok,
       %{
         credential_type_id: type_id,
         organization_id: organization_id,
         injector_digest: injector_digest
       }}
    else
      {:error, :callback_credential_contract_unavailable}
    end
  end

  defp effective_authority(user) do
    case RBAC.effective_authority(user, @actor) do
      {:ok, %{permissions: %MapSet{} = permissions, profile_versions: profile_versions}} ->
        {:ok, %{permissions: permissions, profile_versions: profile_versions}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required({:ok, nil}), do: {:error, :record_not_found}
  defp required({:ok, value}), do: {:ok, value}
  defp required({:error, reason}), do: {:error, reason}

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

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
