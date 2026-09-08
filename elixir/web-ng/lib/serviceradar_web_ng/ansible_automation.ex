defmodule ServiceRadarWebNG.AnsibleAutomation do
  @moduledoc "Canonical Ansible operations and exact membership review for the authenticated API."

  alias ServiceRadar.Automation.Ansible.AwxBindingReview
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipApproval
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.SecureLaunchService
  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistory

  @membership_fields ~w(id controller_id inventory_id awx_host_id canonical_device_uid host_name ansible_host enabled current link_disposition source_fingerprint last_seen_at)a
  @binding_fields ~w(id controller_id job_template_id binding_version current approval_state approval_expires_at inventory_policy allowed_inventory_ids project_id scm_revision content_sha256 execution_environment_id run_mode_supported check_mode_supported reviewed_at reviewed_launch_snapshot_digest)a
  @operation_states ~w(planned dispatching running succeeded failed canceled dispatch_partial dispatch_ambiguous cancel_failed)a

  def list_operations(scope, params) do
    with :ok <- exact_keys(params, ["state"]),
         {:ok, state} <- optional_state(params["state"]) do
      AutomationHistory.list_operations(scope, state)
    end
  end

  def get_operation(scope, id), do: AutomationHistory.get_operation_bundle(id, scope)

  def prepare(scope, params) do
    with :ok <- exact_keys(params, ["device_uids", "playbook_id"]),
         {:ok, resolution} <-
           SecureLaunchService.prepare(scope.user, params["device_uids"], params["playbook_id"]) do
      variables =
        Enum.map(
          resolution.variables,
          &Map.take(&1, [:name, :label, :type, :required, :choices, :min, :max, :help])
        )

      projection =
        Map.take(
          resolution,
          ~w(playbook_id playbook_name membership_ids device_uids controller_id inventory_id job_template_id run_mode_supported check_mode_supported binding_version approval_expires_at)a
        )

      {:ok, Map.put(projection, :variables, variables)}
    end
  end

  def launch(scope, params) do
    with :ok <- exact_keys(params, ["device_uids", "playbook_id", "inputs", "mode"]),
         {:ok, mode} <- launch_mode(Map.get(params, "mode", "run")),
         {:ok, persisted} <-
           SecureLaunchService.launch(
             scope.user,
             params["device_uids"],
             params["playbook_id"],
             Map.get(params, "inputs", %{}),
             mode: mode,
             request_source: :serviceradar_api
           ) do
      get_operation(scope, persisted.operation.id)
    end
  end

  def request_cancel(_scope, _id), do: {:error, :cancellation_not_implemented}

  def list_memberships(scope, params) do
    with :ok <- exact_keys(params, ["controller_id", "inventory_id"]),
         {:ok, inventory_id} <- positive_integer(params["inventory_id"]),
         {:ok, memberships} <-
           AwxHostMembership.list_current_for_inventory(params["controller_id"], inventory_id,
             scope: scope
           ) do
      {:ok, Enum.map(memberships, &membership_view/1)}
    end
  end

  def approve_membership(scope, id, params) do
    with :ok <-
           exact_keys(
             params,
             ~w(controller_id inventory_id awx_host_id canonical_device_uid source_generation source_fingerprint link_evidence_digest)
           ),
         {:ok, approved} <-
           AwxMembershipApproval.approve(Map.put(params, "membership_id", id), scope) do
      {:ok, membership_view(approved)}
    end
  end

  def list_bindings(scope, params) do
    with :ok <- exact_keys(params, ["controller_id", "job_template_id"]),
         {:ok, template_id} <- positive_integer(params["job_template_id"]),
         {:ok, bindings} <-
           AwxTemplateBinding.list_versions_for_template(params["controller_id"], template_id,
             scope: scope
           ) do
      {:ok, Enum.map(bindings, &binding_view/1)}
    end
  end

  def prepare_binding(scope, params), do: AwxBindingReview.prepare(params, scope)

  def create_binding(scope, params) do
    with {:ok, binding} <- AwxBindingReview.create(params, scope),
         do: {:ok, binding_view(binding)}
  end

  def revoke_binding(scope, id, params) do
    with :ok <- exact_keys(params, []),
         {:ok, binding} <- AwxBindingReview.revoke(id, scope),
         do: {:ok, binding_view(binding)}
  end

  def binding_view(binding), do: Map.take(binding, @binding_fields)

  defp membership_view(membership) do
    digest =
      case AwxMembershipApproval.link_evidence_digest(membership.link_evidence || %{}) do
        {:ok, value} -> value
        _ -> nil
      end

    membership
    |> Map.take(@membership_fields)
    |> Map.put(:source_generation, to_string(membership.source_generation))
    |> Map.put(:link_evidence_digest, digest)
    |> Map.put(
      :link_evidence,
      Map.take(
        membership.link_evidence || %{},
        ~w(kind controller_id inventory_id awx_host_id matching_device_uids match_count)
      )
    )
  end

  defp exact_keys(params, allowed) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, :unreviewed_request_fields}
  end

  defp exact_keys(_, _), do: {:error, :invalid_request}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :invalid_identifier}

      _ ->
        {:error, :invalid_identifier}
    end
  end

  defp positive_integer(_), do: {:error, :invalid_identifier}
  defp launch_mode("run"), do: {:ok, :run}
  defp launch_mode("check"), do: {:ok, :check}
  defp launch_mode(_), do: {:error, :invalid_launch_mode}
  defp optional_state(nil), do: {:ok, nil}

  defp optional_state(value) do
    case Enum.find(@operation_states, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_operation_state}
      state -> {:ok, state}
    end
  end
end
