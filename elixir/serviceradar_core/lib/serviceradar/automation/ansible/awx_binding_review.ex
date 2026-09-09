defmodule ServiceRadar.Automation.Ansible.AwxBindingReview do
  @moduledoc """
  Human review of non-callback bindings using fresh, broker-observed AWX facts.

  Prepare displays a complete review contract. Create independently repeats
  those reads and compares its digest before assigning approval identity and
  replacing the current version. Caller-supplied snapshots are never accepted.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerProvenance
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.SecurityEvent

  @actor SystemActor.system(:awx_binding_review)
  @keys ~w(controller_id template_id project_id inventory_id credential_ids execution_environment_id membership_ids machine_credential_id content_sha256 input_schema input_classifications review_ticket approval_ttl_seconds)
  @permission "ansible.controllers.manage"

  def prepare(request, scope, opts \\ []) do
    deps = dependencies(opts)

    with :ok <- request_keys(request, @keys),
         {:ok, request} <- normalize_request(request),
         {:ok, _user} <- current_reviewer(scope, deps),
         {:ok, review} <- deps.fetch_review.(request),
         {:ok, digest} <- CanonicalJSON.digest(review) do
      {:ok, %{review: review, review_digest: digest}}
    end
  end

  def create(request, scope, opts \\ []) do
    deps = dependencies(opts)

    with :ok <- request_keys(request, ["expected_review_digest" | @keys]),
         expected when is_binary(expected) <- request["expected_review_digest"],
         {:ok, %{review: review, review_digest: ^expected}} <-
           prepare(Map.delete(request, "expected_review_digest"), scope, opts),
         {:ok, user} <- current_reviewer(scope, deps) do
      deps.persist_review.(review, user)
    else
      {:ok, _changed_review} -> {:error, :binding_review_changed}
      {:error, _reason} = error -> error
      _ -> {:error, :binding_review_digest_required}
    end
  end

  def revoke(id, scope, opts \\ []) do
    deps = dependencies(opts)

    with {:ok, user} <- current_reviewer(scope, deps) do
      deps.revoke_binding.(id, user)
    end
  end

  defp normalize_request(request) do
    with {:ok, controller_id} <- Ecto.UUID.cast(request["controller_id"]),
         {:ok, template_id} <- positive_id(request["template_id"]),
         {:ok, project_id} <- positive_id(request["project_id"]),
         {:ok, inventory_id} <- positive_id(request["inventory_id"]),
         {:ok, environment_id} <- positive_id(request["execution_environment_id"]),
         {:ok, machine_id} <- positive_id(request["machine_credential_id"]),
         {:ok, credentials} <- id_list(request["credential_ids"]),
         true <-
           is_list(request["membership_ids"]) and length(request["membership_ids"]) in 1..100,
         true <- Enum.all?(request["membership_ids"], &match?({:ok, _}, Ecto.UUID.cast(&1))),
         true <-
           is_binary(request["content_sha256"]) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, request["content_sha256"]),
         true <-
           is_binary(request["review_ticket"]) and byte_size(request["review_ticket"]) in 1..255,
         true <-
           is_map(Map.get(request, "input_schema", %{})) and
             is_map(Map.get(request, "input_classifications", %{})),
         {:ok, ttl} <- approval_ttl(request["approval_ttl_seconds"]) do
      {:ok,
       Map.merge(request, %{
         "controller_id" => controller_id,
         "template_id" => template_id,
         "project_id" => project_id,
         "inventory_id" => inventory_id,
         "execution_environment_id" => environment_id,
         "machine_credential_id" => machine_id,
         "credential_ids" => credentials,
         "approval_ttl_seconds" => ttl
       })}
    else
      _ -> {:error, :invalid_binding_review_request}
    end
  end

  defp id_list(values) when is_list(values) and length(values) in 1..128 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case positive_id(value) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp id_list(_), do: {:error, :invalid_identifier}

  defp dependencies(opts) do
    Map.merge(
      %{
        load_user: &User.get_by_id(&1, actor: @actor),
        load_authority: &RBAC.effective_authority(&1, @actor),
        fetch_review: &fetch_review/1,
        persist_review: &persist_review/2,
        revoke_binding: &revoke_binding/2
      },
      Keyword.get(opts, :dependencies, %{})
    )
  end

  defp current_reviewer(scope, deps) do
    actor = Map.get(scope, :user, scope)

    with %{id: id} when not is_nil(id) <- actor,
         true <- Map.get(actor, :role) not in [:system, "system"],
         true <- Map.get(actor, :principal_type, :human) in [:human, "human"],
         {:ok, %{id: ^id, status: :active} = user} <- deps.load_user.(id),
         true <- Map.get(user, :role) not in [:system, "system"],
         {:ok, %{permissions: %MapSet{} = permissions}} <- deps.load_authority.(user),
         true <- MapSet.member?(permissions, @permission) do
      {:ok, user}
    else
      _ -> {:error, :current_permission_denied}
    end
  end

  defp fetch_review(request) do
    with {:ok, ttl} <- approval_ttl(request["approval_ttl_seconds"]),
         {:ok, controller} when not is_nil(controller) <-
           Controller.get_by_id(request["controller_id"], actor: @actor),
         {:ok, boundary} <- ControllerSecuritySnapshot.capture(controller),
         {:ok, %{agent_id: agent_id, partition_id: partition}} <-
           AgentCommandBus.resolve_control_session_evidence(controller.agent_id),
         true <- agent_id == controller.agent_id,
         {:ok, hosts} <- selected_hosts(request),
         {:ok, preflight_request} <- preflight_request(request, hosts),
         provenance_opts = [
           expected_controller_snapshot: boundary,
           expected_partition_id: partition
         ],
         {:ok, result} <-
           ControllerProvenance.fetch_launch_preflight(
             controller,
             preflight_request,
             provenance_opts
           ),
         {:ok, snapshot} <- AwxLaunchContract.static_projection(result.preflight),
         {:ok, digest} <- AwxLaunchContract.digest(snapshot),
         {:ok, groups} <-
           ControllerProvenance.list_inventory_groups(
             controller,
             String.to_integer(snapshot["inventory"]["id"]),
             provenance_opts
           ),
         {:ok, principal_id} <- ControllerProvenance.current_user(controller, provenance_opts),
         {:ok, attrs} <- binding_attributes(request, snapshot, digest, groups, principal_id),
         :ok <- validate_draft(attrs, ttl) do
      {:ok, %{"attributes" => attrs, "approval_ttl_seconds" => ttl}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :binding_review_unavailable}
    end
  end

  defp selected_hosts(%{"membership_ids" => ids} = request)
       when is_list(ids) and length(ids) in 1..100 do
    if Enum.uniq(ids) == ids do
      ids
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, hosts} ->
        with {:ok, membership} when not is_nil(membership) <-
               AwxHostMembership.get_by_id(id, actor: @actor),
             true <-
               membership.current and membership.enabled and
                 membership.link_disposition == :approved,
             true <- membership.controller_id == request["controller_id"],
             true <- to_string(membership.inventory_id) == to_string(request["inventory_id"]) do
          host = %{
            "membership_id" => membership.id,
            "controller_id" => membership.controller_id,
            "inventory_id" => to_string(membership.inventory_id),
            "awx_host_id" => to_string(membership.awx_host_id),
            "canonical_device_uid" => membership.canonical_device_uid,
            "host_name" => membership.host_name,
            "ansible_host" => membership.ansible_host,
            "enabled" => true,
            "membership_generation" => to_string(membership.source_generation),
            "source_fingerprint" => membership.source_fingerprint
          }

          {:cont, {:ok, [host | hosts]}}
        else
          _ -> {:halt, {:error, :review_membership_unavailable}}
        end
      end)
      |> case do
        {:ok, hosts} -> {:ok, Enum.sort_by(hosts, &String.to_integer(&1["awx_host_id"]))}
        error -> error
      end
    else
      {:error, :review_memberships_must_be_unique}
    end
  end

  defp selected_hosts(_request), do: {:error, :review_memberships_required}

  defp preflight_request(request, hosts) do
    if is_list(request["credential_ids"]) do
      request
      |> Map.take(~w(controller_id template_id project_id inventory_id execution_environment_id))
      |> Map.new(fn {key, value} -> {key, to_string(value)} end)
      |> Map.put(
        "credential_ids",
        request["credential_ids"] |> Enum.sort() |> Enum.map(&to_string/1)
      )
      |> Map.put("selected_hosts", hosts)
      |> Map.put("schema", AwxLaunchContract.request_schema())
      |> AwxLaunchContract.validate_request()
    else
      {:error, :review_credential_ids_required}
    end
  end

  defp binding_attributes(request, snapshot, digest, groups, principal_id) do
    template = snapshot["template"]
    prompts = template["prompt_on_launch"]

    credentials =
      Enum.map(
        snapshot["credentials"],
        &%{"id" => String.to_integer(&1["id"]), "kind" => &1["type"]["kind"]}
      )

    with {:ok, machine_id} <- positive_id(request["machine_credential_id"]),
         true <- Enum.any?(credentials, &(&1 == %{"id" => machine_id, "kind" => "ssh"})) do
      {:ok,
       %{
         "controller_id" => snapshot["controller_id"],
         "job_template_id" => String.to_integer(template["id"]),
         "inventory_policy" => "fixed",
         "allowed_inventory_ids" => [String.to_integer(snapshot["inventory"]["id"])],
         "project_id" => String.to_integer(snapshot["project"]["id"]),
         "scm_revision" => snapshot["project"]["scm_revision"],
         "content_sha256" => request["content_sha256"],
         "project_update_on_launch" => false,
         "execution_environment_id" => String.to_integer(snapshot["execution_environment"]["id"]),
         "credentials" => credentials,
         "machine_credential_id" => machine_id,
         "run_mode_supported" =>
           template["job_type"] == "run" or prompts["ask_job_type_on_launch"],
         "check_mode_supported" =>
           template["job_type"] == "check" or prompts["ask_job_type_on_launch"],
         "ask_inventory_on_launch" => prompts["ask_inventory_on_launch"],
         "ask_limit_on_launch" => prompts["ask_limit_on_launch"],
         "ask_credential_on_launch" => prompts["ask_credential_on_launch"],
         "ask_job_type_on_launch" => prompts["ask_job_type_on_launch"],
         "dispatch_markers_retained" => true,
         "inventory_groups_verified" => true,
         "inventory_group_names" => Enum.sort(groups),
         "input_schema" => Map.get(request, "input_schema", %{}),
         "input_classifications" => Map.get(request, "input_classifications", %{}),
         "callback_actions" => [],
         "awx_created_by_id" => principal_id,
         "review_metadata" => %{
           "review_ticket" => request["review_ticket"],
           "awx_snapshot_digest" => digest,
           "source_ref" => snapshot["project"]["scm_revision"],
           "dispatch_marker_contract" => DispatchMarkerContract.contract()
         },
         "reviewed_launch_snapshot" => snapshot,
         "reviewed_launch_snapshot_digest" => digest
       }}
    else
      _ -> {:error, :review_machine_credential_invalid}
    end
  end

  defp validate_draft(attrs, ttl) do
    changeset =
      Ash.Changeset.for_create(
        AwxTemplateBinding,
        :create_version,
        approval_attrs(attrs, ttl, Ash.UUID.generate(), 1),
        actor: @actor
      )

    if changeset.valid?, do: :ok, else: {:error, :binding_review_contract_invalid}
  end

  defp persist_review(review, user) do
    attrs = review["attributes"]

    Repo.transaction(fn ->
      lock_template(attrs["controller_id"], attrs["job_template_id"])

      {:ok, versions} =
        AwxTemplateBinding.list_versions_for_template(
          attrs["controller_id"],
          attrs["job_template_id"],
          actor: @actor
        )

      version = Enum.reduce(versions, 0, &max(&1.binding_version, &2)) + 1
      Enum.each(Enum.filter(versions, & &1.current), &supersede!/1)

      case AwxTemplateBinding.create_version(
             approval_attrs(attrs, review["approval_ttl_seconds"], user.id, version),
             actor: @actor
           ) do
        {:ok, binding} -> binding
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp revoke_binding(id, user) do
    Repo.transaction(fn ->
      with {:ok, binding} when not is_nil(binding) <-
             AwxTemplateBinding.get_by_id(id, actor: @actor),
           {:ok, revoked} <- AwxTemplateBinding.revoke(binding, %{}, actor: @actor),
           {:ok, _audit} <-
             SecurityEvent.record(
               %{
                 kind: :other,
                 severity: :info,
                 actor_id: user.id,
                 details: %{
                   "action" => "ansible.template_binding.revoked",
                   "binding_id" => binding.id,
                   "controller_id" => binding.controller_id,
                   "job_template_id" => binding.job_template_id,
                   "binding_version" => binding.binding_version
                 }
               },
               actor: @actor
             ) do
        revoked
      else
        {:ok, nil} -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp approval_attrs(attrs, ttl, reviewer_id, version) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Map.merge(attrs, %{
      "binding_version" => version,
      "current" => true,
      "approval_state" => "approved",
      "approval_id" => Ash.UUID.generate(),
      "approval_expires_at" => DateTime.add(now, ttl, :second),
      "reviewed_by_principal_type" => "human",
      "reviewed_by_principal_id" => reviewer_id,
      "reviewed_at" => now
    })
  end

  defp supersede!(binding) do
    case AwxTemplateBinding.supersede(binding, %{}, actor: @actor) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_template(controller_id, template_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "awx-binding:" <> controller_id <> ":" <> to_string(template_id)
    ])
  end

  defp request_keys(request, allowed) when is_map(request) do
    if Enum.all?(Map.keys(request), &(&1 in allowed)),
      do: :ok,
      else: {:error, :unreviewed_request_fields}
  end

  defp request_keys(_, _), do: {:error, :invalid_binding_review_request}
  defp approval_ttl(nil), do: {:ok, 3_600}
  defp approval_ttl(value) when is_integer(value) and value in 60..86_400, do: {:ok, value}
  defp approval_ttl(_), do: {:error, :invalid_approval_ttl}
  defp positive_id(value) when is_integer(value) and value in 1..2_147_483_647, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id in 1..2_147_483_647 ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :invalid_identifier}

      _ ->
        {:error, :invalid_identifier}
    end
  end

  defp positive_id(_), do: {:error, :invalid_identifier}
end
