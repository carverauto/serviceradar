defmodule ServiceRadarWebNG.AnsibleAutomation do
  @moduledoc """
  Canonical Ansible operations and exact membership and binding review.

  The authenticated API and the Ansible settings review UI both call this
  module with the initiating user's scope, so RBAC and the human-principal
  requirement are enforced by the same domain services for both surfaces.
  """

  alias ServiceRadar.Automation.Ansible.AwxBindingReview
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipApproval
  alias ServiceRadar.Automation.Ansible.AwxMembershipQuarantineRelease
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.SecureLaunchService
  alias ServiceRadarWebNG.AnsibleAutomation.History, as: AutomationHistory

  require Ash.Query

  @membership_fields ~w(id controller_id inventory_id awx_host_id canonical_device_uid host_name ansible_host enabled current link_disposition quarantine_reason quarantined_at source_fingerprint last_seen_at)a
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
           AwxHostMembership.list_current_for_inventory(params["controller_id"], inventory_id, scope: scope) do
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

  @doc """
  Releases one quarantined membership as the scope's user from the exact
  evidence displayed. The result is `proposed` when one device matches now and
  `unlinked` when none does; it is never `approved`. Several matches are
  refused as `{:error, {:membership_link_ambiguous, device_uids}}`.
  """
  def release_membership(scope, id, params) do
    with :ok <-
           exact_keys(
             params,
             ~w(controller_id inventory_id awx_host_id source_generation source_fingerprint link_evidence_digest)
           ),
         {:ok, released} <-
           AwxMembershipQuarantineRelease.release(Map.put(params, "membership_id", id), scope) do
      {:ok, membership_view(released)}
    end
  end

  def list_bindings(scope, params) do
    with :ok <- exact_keys(params, ["controller_id", "job_template_id"]),
         {:ok, template_id} <- positive_integer(params["job_template_id"]),
         {:ok, bindings} <-
           AwxTemplateBinding.list_versions_for_template(params["controller_id"], template_id, scope: scope) do
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

  @doc """
  Lists the AWX inventories that hold current memberships for one controller,
  with the number of proposals in each that await human review.

  Reads use the caller's scope, so they require the same `ansible.runs.view`
  authority as `list_memberships/2`.
  """
  def list_membership_inventories(scope, controller_id) do
    with {:ok, controller_id} <- uuid(controller_id),
         {:ok, inventories} <-
           controller_id
           |> current_memberships_query()
           |> Ash.Query.distinct(:inventory_id)
           |> Ash.read(scope: scope),
         {:ok, proposals} <-
           controller_id
           |> current_memberships_query()
           |> Ash.Query.filter(link_disposition == :proposed and enabled == true)
           |> Ash.read(scope: scope) do
      counts = Enum.frequencies_by(proposals, & &1.inventory_id)

      {:ok,
       inventories
       |> Enum.map(& &1.inventory_id)
       |> Enum.uniq()
       |> Enum.sort()
       |> Enum.map(&%{inventory_id: &1, needs_review: Map.get(counts, &1, 0)})}
    end
  end

  @doc """
  Lists the AWX-sourced catalog rows of one controller that carry a job
  template id, with the project and inventory ids the catalog sync recorded.

  These are hints for the binding review form only; prepare re-reads AWX
  through the broker and its review is the authority. Requires
  `ansible.catalog.view` through the caller's scope.
  """
  def list_binding_templates(scope, controller_id) do
    with {:ok, controller_id} <- uuid(controller_id),
         {:ok, playbooks} <- Playbook.list_by_controller(controller_id, scope: scope) do
      {:ok,
       playbooks
       |> Enum.filter(&(&1.source_type == :awx and is_integer(&1.awx_job_template_id)))
       |> Enum.map(&template_view/1)
       |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.job_template_id})}
    end
  end

  defp current_memberships_query(controller_id) do
    AwxHostMembership
    |> Ash.Query.filter(controller_id == ^controller_id and current == true)
    |> Ash.Query.select([:inventory_id])
  end

  defp template_view(playbook) do
    metadata = playbook.metadata || %{}

    %{
      playbook_id: playbook.id,
      name: playbook.name,
      job_template_id: playbook.awx_job_template_id,
      project_id: optional_awx_id(Map.get(metadata, "project")),
      inventory_id: optional_awx_id(Map.get(metadata, "inventory"))
    }
  end

  defp optional_awx_id(value) when is_integer(value) and value > 0, do: value
  defp optional_awx_id(_value), do: nil

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_identifier}
    end
  end

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
