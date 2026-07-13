defmodule ServiceRadar.Automation.CallbackGrants.CurrentAuthority do
  @moduledoc """
  Reconstructs callback authority from current persisted state.

  Callback HTTP credentials never become authorization evidence. Each check
  reloads the initiating principal (or the owner of an OAuth service
  principal), role profile, operation, execution, reviewed binding, exact AWX
  memberships, execution targets, and device-wide holds. Any missing,
  ambiguous, or contracted state fails closed.
  """

  @behaviour ServiceRadar.Automation.CallbackGrants.Authorizer

  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.CurrentAuthorityAshSource

  @action "remote_access.ssh_ca.bundle.read"
  @required_permissions [
    "ansible.runs.launch",
    "devices.remote_access.ssh.ca_bundle.read"
  ]
  @active_operation_states [:planned, :dispatching, :running]
  @accepted_execution_states [:launching, :scope_verified, :running]
  @verified_execution_states [:scope_verified, :running]
  @approval_snapshot_keys MapSet.new([
                            "binding_id",
                            "binding_version",
                            "approval_id",
                            "approval_expires_at",
                            "reviewed_by_principal_type",
                            "reviewed_by_principal_id",
                            "reviewed_at",
                            "review_metadata",
                            "issued_at"
                          ])
  @policy_schema "serviceradar.automation_callback_policy/v1"
  @policy_snapshot_keys MapSet.new([
                          "schema",
                          "action",
                          "binding_id",
                          "binding_version",
                          "version",
                          "approval_id",
                          "approval_state",
                          "approval_expires_at"
                        ])
  @max_approval_snapshot_age_seconds 300

  @impl true
  def current_authority(stage, grant, context)
      when stage in [:issue, :bind_credential, :activate, :use, :replay] and is_map(grant) do
    source = source(context)
    now = now(context)
    principal_type = normalize_principal_type(value(grant, :principal_type))
    scope = value(grant, :awx_scope_snapshot) || %{}

    membership_ids =
      scope |> value(:targets) |> List.wrap() |> Enum.map(&value(&1, :membership_id))

    with true <- principal_type in [:human, :service_principal] || {:error, :principal_changed},
         :ok <- exact_nonempty_ids(membership_ids),
         {:ok, principal} <-
           source.load_principal(
             principal_type,
             to_string(value(grant, :principal_id)),
             optional_string(value(grant, :principal_owner_id))
           ),
         {:ok, operation} <- source.load_operation(value(grant, :parent_run_id)),
         {:ok, execution} <- source.load_execution(value(grant, :execution_id)),
         {:ok, execution_targets} <-
           source.load_execution_targets(value(grant, :execution_id)),
         {:ok, memberships} <- source.load_memberships(membership_ids),
         {:ok, binding} <-
           source.load_current_binding(
             value(scope, :controller_id),
             value(scope, :job_template_id)
           ),
         {:ok, callback_contract} <- source.callback_credential_contract(),
         {:ok, rebuilt} <-
           rebuild(
             stage,
             grant,
             principal,
             operation,
             execution,
             execution_targets,
             memberships,
             binding,
             callback_contract,
             now
           ),
         {:ok, holds} <- source.active_holds(rebuilt.device_uids),
         true <- holds == [] || {:error, :target_policy_changed} do
      {:ok, rebuilt.authority}
    else
      false -> {:error, :current_authority_required}
      {:error, _} = error -> error
      _ -> {:error, :current_authority_required}
    end
  rescue
    _ -> {:error, :current_authority_required}
  end

  def current_authority(_stage, _grant, _context), do: {:error, :current_authority_required}

  defp rebuild(
         stage,
         grant,
         principal_data,
         operation,
         execution,
         execution_targets,
         memberships,
         binding,
         callback_contract,
         now
       ) do
    scope = value(grant, :awx_scope_snapshot) || %{}

    with {:ok, principal} <- current_principal(grant, principal_data, now),
         :ok <- exact_operation(grant, operation, principal),
         :ok <- exact_execution(grant, operation, execution),
         :ok <- current_binding(grant, binding, callback_contract, now),
         {:ok, approval_snapshot} <- current_approval_snapshot(grant, binding, now),
         {:ok, policy_snapshot} <- current_policy_snapshot(grant, binding),
         {:ok, targets} <-
           current_targets(grant, execution, execution_targets, memberships),
         :ok <- stage_job(stage, grant, execution, targets),
         {:ok, current_scope} <-
           current_scope(scope, execution, binding, targets, callback_contract),
         {:ok, scope_digest} <- CanonicalJSON.digest(current_scope),
         {:ok, approval_digest} <- CanonicalJSON.digest(approval_snapshot),
         {:ok, policy_digest} <- CanonicalJSON.digest(policy_snapshot),
         {:ok, target_keys} <- Authority.target_keys(targets),
         true <-
           secure_equal(scope_digest, value(grant, :scope_digest)) ||
             {:error, :awx_binding_changed},
         true <-
           secure_equal(approval_digest, value(grant, :approval_digest)) ||
             {:error, :approval_changed},
         true <-
           secure_equal(policy_digest, value(grant, :policy_digest)) ||
             {:error, :target_policy_changed} do
      authority = %{
        enabled: true,
        principal_type: principal.type,
        principal_id: principal.id,
        principal_owner_id: principal.owner_id,
        tenant_id: value(grant, :tenant_id),
        permissions: principal.permissions,
        actions: [@action],
        target_keys: target_keys,
        approval_digest: approval_digest,
        policy_digest: policy_digest,
        scope_digest: scope_digest,
        run_state: operation_run_state(value(operation, :state)),
        job_state: execution_job_state(value(execution, :state)),
        job_id: value(execution, :awx_job_id)
      }

      {:ok, %{authority: authority, device_uids: Enum.map(targets, & &1.canonical_device_uid)}}
    else
      false -> {:error, :current_authority_required}
      {:error, _} = error -> error
    end
  end

  defp current_principal(grant, %{principal: principal, owner: owner, profile: profile}, now) do
    type = normalize_principal_type(value(grant, :principal_type))

    profile_permissions =
      profile |> value(:permissions) |> List.wrap() |> Enum.sort() |> Enum.uniq()

    permissions =
      if type == :human or service_principal_write_scope?(principal),
        do: profile_permissions,
        else: []

    id = if type == :human, do: value(owner, :id), else: value(principal, :id)
    owner_id = if type == :service_principal, do: value(owner, :id)

    with true <- value(owner, :status) in [:active, "active"] || {:error, :principal_disabled},
         true <-
           to_string(id) == to_string(value(grant, :principal_id)) || {:error, :principal_changed},
         true <-
           (type != :service_principal or
              service_principal_active?(principal, owner_id, grant, now)) ||
             {:error, :principal_disabled},
         true <-
           Enum.all?(@required_permissions, &(&1 in permissions)) ||
             {:error, :current_permission_denied},
         authorization_version =
           authorization_version(type, principal, owner, profile, profile_permissions),
         true <-
           secure_equal(authorization_version, to_string(value(grant, :authorization_version))) ||
             {:error, :principal_changed} do
      {:ok,
       %{
         type: type,
         id: to_string(id),
         owner_id: optional_string(owner_id),
         permissions: permissions,
         authorization_version: authorization_version
       }}
    else
      false -> {:error, :principal_changed}
      {:error, _} = error -> error
    end
  end

  defp current_principal(_grant, _principal, _now), do: {:error, :current_authority_required}

  defp exact_operation(grant, operation, principal) do
    ceiling = value(operation, :authority_ceiling) || %{}

    ceiling_memberships =
      ceiling |> value(:target_membership_ids) |> List.wrap() |> Enum.map(&to_string/1)

    ceiling_permissions = ceiling |> value(:permissions) |> List.wrap()
    grant_memberships = target_membership_ids(grant)

    cond do
      to_string(value(operation, :id)) != to_string(value(grant, :parent_run_id)) ->
        {:error, :run_not_active}

      to_string(value(operation, :tenant_id)) != to_string(value(grant, :tenant_id)) ->
        {:error, :tenant_changed}

      normalize_principal_type(value(operation, :initiator_principal_type)) != principal.type ->
        {:error, :principal_changed}

      to_string(value(operation, :initiator_principal_id)) != principal.id ->
        {:error, :principal_changed}

      optional_string(value(operation, :service_principal_owner_id)) != principal.owner_id ->
        {:error, :service_principal_owner_changed}

      not secure_equal(
        to_string(value(operation, :authorization_version)),
        principal.authorization_version
      ) ->
        {:error, :principal_changed}

      value(operation, :state) not in @active_operation_states ->
        {:error, :run_not_active}

      @action not in List.wrap(value(operation, :callback_actions)) ->
        {:error, :action_no_longer_authorized}

      not Enum.all?(@required_permissions, &(&1 in ceiling_permissions)) ->
        {:error, :current_permission_denied}

      Enum.sort(ceiling_memberships) != Enum.sort(grant_memberships) ->
        {:error, :target_no_longer_authorized}

      true ->
        :ok
    end
  end

  defp exact_execution(grant, operation, execution) do
    scope = value(grant, :awx_scope_snapshot) || %{}

    checks = [
      {value(execution, :id), value(grant, :execution_id)},
      {value(execution, :operation_id), value(operation, :id)},
      {value(execution, :controller_id), value(scope, :controller_id)},
      {value(execution, :inventory_id), value(scope, :inventory_id)},
      {value(execution, :job_template_id), value(scope, :job_template_id)},
      {value(execution, :project_id), value(scope, :project_id)},
      {value(execution, :scm_revision), value(scope, :scm_revision)},
      {value(execution, :content_sha256), value(scope, :content_sha256)},
      {value(execution, :execution_environment_id), value(scope, :execution_environment_id)},
      {value(execution, :machine_credential_id), value(scope, :machine_credential_id)},
      {value(execution, :host_limit), value(scope, :host_limit)},
      {value(execution, :snapshot_digest), value(scope, :snapshot_digest)},
      {value(value(execution, :metadata) || %{}, :target_digest), value(scope, :target_digest)}
    ]

    if Enum.all?(checks, fn {left, right} -> to_string(left) == to_string(right) end),
      do: :ok,
      else: {:error, :awx_binding_changed}
  end

  defp current_binding(grant, binding, callback_contract, now) do
    scope = value(grant, :awx_scope_snapshot) || %{}
    actions = List.wrap(value(binding, :callback_actions))
    binding_type_id = value(binding, :callback_credential_type_id)
    binding_organization_id = value(binding, :callback_credential_organization_id)
    binding_injector_digest = value(binding, :callback_credential_injector_digest)
    allowed_inventory_ids = List.wrap(value(binding, :allowed_inventory_ids))

    cond do
      to_string(value(binding, :id)) != to_string(value(scope, :binding_id)) ->
        {:error, :awx_binding_changed}

      value(binding, :current) != true ->
        {:error, :awx_binding_changed}

      to_string(value(binding, :controller_id)) != to_string(value(scope, :controller_id)) ->
        {:error, :awx_binding_changed}

      value(binding, :job_template_id) != value(scope, :job_template_id) ->
        {:error, :awx_binding_changed}

      value(scope, :inventory_id) not in allowed_inventory_ids ->
        {:error, :awx_binding_changed}

      value(binding, :approval_state) not in [:approved, "approved"] ->
        {:error, :approval_changed}

      not positive_integer?(value(binding, :binding_version)) or
          blank?(value(binding, :approval_id)) ->
        {:error, :approval_changed}

      not future?(value(binding, :approval_expires_at), now) ->
        {:error, :approval_changed}

      value(binding, :reviewed_by_principal_type) not in [
        :human,
        "human",
        :service_principal,
        "service_principal"
      ] ->
        {:error, :approval_changed}

      blank?(value(binding, :reviewed_by_principal_id)) or
        not match?(%DateTime{}, value(binding, :reviewed_at)) or
          DateTime.after?(value(binding, :reviewed_at), now) ->
        {:error, :approval_changed}

      @action not in actions ->
        {:error, :action_no_longer_authorized}

      binding_type_id != callback_contract.credential_type_id ->
        {:error, :awx_binding_changed}

      binding_organization_id != callback_contract.organization_id ->
        {:error, :awx_binding_changed}

      not secure_equal(to_string(binding_injector_digest), callback_contract.injector_digest) ->
        {:error, :awx_binding_changed}

      value(scope, :callback_credential_type_id) != binding_type_id ->
        {:error, :awx_binding_changed}

      value(scope, :callback_credential_organization_id) != binding_organization_id ->
        {:error, :awx_binding_changed}

      not secure_equal(
        to_string(value(scope, :callback_credential_injector_digest)),
        to_string(binding_injector_digest)
      ) ->
        {:error, :awx_binding_changed}

      blank?(policy_version(binding)) ->
        {:error, :target_policy_changed}

      true ->
        :ok
    end
  end

  defp current_targets(grant, execution, execution_targets, memberships) do
    expected = (value(grant, :awx_scope_snapshot) || %{}) |> value(:targets) |> List.wrap()
    expected_ids = Enum.map(expected, &to_string(value(&1, :membership_id)))
    membership_by_id = Map.new(memberships, &{to_string(value(&1, :id)), &1})

    execution_by_membership =
      Map.new(execution_targets, &{to_string(value(&1, :membership_id)), &1})

    with true <-
           (map_size(membership_by_id) == length(expected_ids) and
              map_size(execution_by_membership) == length(expected_ids)) ||
             {:error, :target_no_longer_authorized},
         {:ok, targets} <-
           Enum.reduce_while(expected, {:ok, []}, fn frozen, {:ok, targets} ->
             id = to_string(value(frozen, :membership_id))
             membership = Map.get(membership_by_id, id)
             execution_target = Map.get(execution_by_membership, id)

             case exact_target(execution, frozen, membership, execution_target) do
               {:ok, target} -> {:cont, {:ok, [target | targets]}}
               {:error, _} = error -> {:halt, error}
             end
           end) do
      targets = Enum.sort_by(targets, & &1.awx_host_id)

      if exact_target_digest?(targets, grant),
        do: {:ok, targets},
        else: {:error, :target_no_longer_authorized}
    else
      false -> {:error, :target_no_longer_authorized}
      {:error, _} = error -> error
    end
  end

  defp exact_target(_execution, _frozen, nil, _execution_target),
    do: {:error, :target_no_longer_authorized}

  defp exact_target(_execution, _frozen, _membership, nil),
    do: {:error, :target_no_longer_authorized}

  defp exact_target(execution, frozen, membership, execution_target) do
    target = %{
      membership_id: to_string(value(membership, :id)),
      controller_id: value(membership, :controller_id),
      inventory_id: value(membership, :inventory_id),
      awx_host_id: value(membership, :awx_host_id),
      canonical_device_uid: value(membership, :canonical_device_uid),
      device_uid: value(membership, :canonical_device_uid),
      host_name: value(membership, :host_name),
      awx_host_name: value(membership, :host_name),
      ansible_host: value(membership, :ansible_host),
      membership_generation: value(membership, :source_generation)
    }

    checks = [
      value(membership, :current) == true,
      value(membership, :enabled) == true,
      value(membership, :link_disposition) in [:approved, "approved"],
      to_string(target.controller_id) == to_string(value(frozen, :controller_id)),
      target.inventory_id == value(frozen, :inventory_id),
      target.awx_host_id == value(frozen, :awx_host_id),
      target.canonical_device_uid ==
        (value(frozen, :canonical_device_uid) || value(frozen, :device_uid)),
      target.host_name == (value(frozen, :host_name) || value(frozen, :awx_host_name)),
      target.ansible_host == value(frozen, :ansible_host),
      target.membership_generation == value(frozen, :membership_generation),
      to_string(value(execution_target, :execution_id)) == to_string(value(execution, :id)),
      to_string(value(execution_target, :controller_id)) == to_string(target.controller_id),
      value(execution_target, :inventory_id) == target.inventory_id,
      value(execution_target, :awx_host_id) == target.awx_host_id,
      value(execution_target, :canonical_device_uid) == target.canonical_device_uid,
      value(execution_target, :membership_generation) == target.membership_generation,
      value(execution_target, :host_name) == target.host_name,
      value(execution_target, :ansible_host) == target.ansible_host
    ]

    if Enum.all?(checks), do: {:ok, target}, else: {:error, :target_no_longer_authorized}
  end

  defp exact_target_digest?(targets, grant) do
    expected = value(value(grant, :awx_scope_snapshot) || %{}, :target_digest)
    secure_equal(Targeting.target_digest(targets), to_string(expected))
  end

  defp stage_job(stage, grant, execution, targets) when stage in [:activate, :use, :replay] do
    state = value(execution, :state)
    job_id = value(execution, :awx_job_id)
    grant_job_id = value(value(grant, :job_binding) || %{}, :job_id)
    snapshot = value(execution, :accepted_job_snapshot) || %{}

    with true <- state in @accepted_execution_states || {:error, :job_not_active},
         true <- positive_integer?(job_id) || {:error, :job_binding_required},
         true <- to_string(job_id) == to_string(grant_job_id) || {:error, :job_binding_changed},
         :ok <- exact_accepted_job(execution, grant, snapshot),
         :ok <- verified_scope(stage, execution, snapshot, targets) do
      :ok
    else
      false -> {:error, :job_not_active}
      {:error, _} = error -> error
    end
  end

  defp stage_job(_stage, _grant, _execution, _targets), do: :ok

  defp exact_accepted_job(execution, grant, snapshot) do
    scope = value(grant, :awx_scope_snapshot) || %{}
    ephemeral_id = value(grant, :ephemeral_credential_id)
    base_ids = List.wrap(value(scope, :credential_ids))
    accepted_ids = snapshot |> value(:credential_ids) |> List.wrap() |> Enum.sort()
    expected_ids = Enum.sort(Enum.uniq(base_ids ++ [ephemeral_id]))

    checks = [
      {value(snapshot, :controller_id), value(execution, :controller_id)},
      {value(snapshot, :awx_job_id), value(execution, :awx_job_id)},
      {value(snapshot, :job_template_id), value(execution, :job_template_id)},
      {value(snapshot, :inventory_id), value(execution, :inventory_id)},
      {value(snapshot, :host_limit), value(execution, :host_limit)},
      {value(snapshot, :project_id), value(execution, :project_id)},
      {value(snapshot, :scm_revision), value(execution, :scm_revision)},
      {value(snapshot, :execution_environment_id), value(execution, :execution_environment_id)},
      {value(snapshot, :awx_created_by_id),
       value(value(execution, :metadata) || %{}, :awx_created_by_id)},
      {value(snapshot, :serviceradar_dispatch_id), value(execution, :dispatch_id)},
      {value(snapshot, :serviceradar_snapshot_digest), value(execution, :snapshot_digest)}
    ]

    cond do
      not positive_integer?(ephemeral_id) ->
        {:error, :callback_credential_not_bound}

      accepted_ids != expected_ids ->
        {:error, :awx_binding_changed}

      not Enum.all?(checks, fn {left, right} -> to_string(left) == to_string(right) end) ->
        {:error, :awx_binding_changed}

      true ->
        :ok
    end
  end

  defp verified_scope(:activate, _execution, _snapshot, _targets), do: :ok

  defp verified_scope(stage, execution, snapshot, targets) when stage in [:use, :replay] do
    evidence = value(snapshot, :scope_verification) || %{}
    expected_host_ids = Enum.map(targets, & &1.awx_host_id)

    cond do
      value(execution, :state) not in @verified_execution_states ->
        {:error, :job_not_active}

      to_string(value(evidence, :execution_id)) != to_string(value(execution, :id)) ->
        {:error, :awx_binding_changed}

      to_string(value(evidence, :controller_id)) !=
          to_string(value(execution, :controller_id)) ->
        {:error, :awx_binding_changed}

      value(evidence, :awx_job_id) != value(execution, :awx_job_id) ->
        {:error, :awx_binding_changed}

      List.wrap(value(evidence, :expected_host_ids)) != expected_host_ids ->
        {:error, :target_no_longer_authorized}

      List.wrap(value(evidence, :observed_host_ids)) != expected_host_ids ->
        {:error, :target_no_longer_authorized}

      true ->
        :ok
    end
  end

  defp current_scope(_scope, execution, binding, targets, callback_contract) do
    with {:ok, credential_ids} <- reviewed_credential_ids(binding),
         execution_credential_ids =
           execution
           |> value(:credential_snapshot)
           |> value(:credential_ids)
           |> List.wrap()
           |> Enum.sort(),
         true <- credential_ids == execution_credential_ids || {:error, :awx_binding_changed},
         true <-
           value(value(execution, :credential_snapshot) || %{}, :dynamic_callback_slot) ==
             value(binding, :callback_credential_slot) || {:error, :awx_binding_changed},
         true <-
           value(binding, :callback_credential_type_id) == callback_contract.credential_type_id ||
             {:error, :awx_binding_changed},
         true <-
           value(binding, :callback_credential_organization_id) ==
             callback_contract.organization_id || {:error, :awx_binding_changed},
         true <-
           secure_equal(
             to_string(value(binding, :callback_credential_injector_digest)),
             callback_contract.injector_digest
           ) || {:error, :awx_binding_changed} do
      {:ok,
       %{
         "controller_id" => value(execution, :controller_id),
         "inventory_id" => value(execution, :inventory_id),
         "job_template_id" => value(execution, :job_template_id),
         "project_id" => value(binding, :project_id),
         "scm_revision" => value(binding, :scm_revision),
         "content_sha256" => value(binding, :content_sha256),
         "execution_environment_id" => value(binding, :execution_environment_id),
         "machine_credential_id" => value(binding, :machine_credential_id),
         "credential_ids" => credential_ids,
         "callback_credential_type_id" => value(binding, :callback_credential_type_id),
         "callback_credential_organization_id" =>
           value(binding, :callback_credential_organization_id),
         "callback_credential_injector_digest" =>
           value(binding, :callback_credential_injector_digest),
         "host_limit" => value(execution, :host_limit),
         "target_count" => length(targets),
         "target_digest" => Targeting.target_digest(targets),
         "snapshot_digest" => value(execution, :snapshot_digest),
         "targets" => Enum.map(targets, &scope_target/1),
         "binding_id" => value(binding, :id),
         "awx_created_by_id" => value(binding, :awx_created_by_id)
       }}
    else
      false -> {:error, :awx_binding_changed}
      {:error, _} = error -> error
    end
  end

  defp reviewed_credential_ids(binding) do
    credentials = List.wrap(value(binding, :credentials))

    with true <- credentials != [] || {:error, :awx_binding_changed},
         true <-
           Enum.all?(credentials, fn credential ->
             is_integer(value(credential, :id)) and value(credential, :id) > 0 and
               is_binary(value(credential, :kind))
           end) || {:error, :awx_binding_changed},
         ids = credentials |> Enum.map(&value(&1, :id)) |> Enum.sort(),
         true <- ids == Enum.uniq(ids) || {:error, :awx_binding_changed},
         machine =
           Enum.find(credentials, &(value(&1, :id) == value(binding, :machine_credential_id))),
         true <- value(machine, :kind) == "ssh" || {:error, :awx_binding_changed} do
      {:ok, ids}
    else
      false -> {:error, :awx_binding_changed}
      {:error, _} = error -> error
    end
  end

  defp scope_target(target) do
    %{
      "membership_id" => target.membership_id,
      "controller_id" => target.controller_id,
      "inventory_id" => target.inventory_id,
      "awx_host_id" => target.awx_host_id,
      "canonical_device_uid" => target.canonical_device_uid,
      "host_name" => target.host_name,
      "ansible_host" => target.ansible_host,
      "membership_generation" => target.membership_generation
    }
  end

  defp current_approval_snapshot(grant, binding, now) do
    snapshot = value(grant, :approval_snapshot)

    with {:ok, normalized} <- normalize_snapshot(snapshot),
         true <-
           MapSet.new(Map.keys(normalized)) == @approval_snapshot_keys ||
             {:error, :approval_changed},
         true <-
           to_string(normalized["binding_id"]) == to_string(value(binding, :id)) ||
             {:error, :approval_changed},
         true <-
           normalized["binding_version"] == value(binding, :binding_version) ||
             {:error, :approval_changed},
         true <-
           to_string(normalized["approval_id"]) == to_string(value(binding, :approval_id)) ||
             {:error, :approval_changed},
         true <-
           normalized["approval_expires_at"] ==
             iso8601(value(binding, :approval_expires_at)) || {:error, :approval_changed},
         true <-
           to_string(normalized["reviewed_by_principal_type"]) ==
             to_string(value(binding, :reviewed_by_principal_type)) ||
             {:error, :approval_changed},
         true <-
           to_string(normalized["reviewed_by_principal_id"]) ==
             to_string(value(binding, :reviewed_by_principal_id)) ||
             {:error, :approval_changed},
         true <-
           normalized["reviewed_at"] == iso8601(value(binding, :reviewed_at)) ||
             {:error, :approval_changed},
         true <-
           canonical_equal?(
             normalized["review_metadata"],
             value(binding, :review_metadata) || %{}
           ) || {:error, :approval_changed},
         {:ok, snapshot_issued_at} <- parse_datetime(normalized["issued_at"]),
         :ok <- bounded_approval_issued_at(snapshot_issued_at, value(grant, :issued_at), now) do
      {:ok, snapshot}
    else
      false -> {:error, :approval_changed}
      {:error, _} = error -> error
    end
  end

  defp current_policy_snapshot(grant, binding) do
    snapshot = value(grant, :policy_snapshot)

    with {:ok, normalized} <- normalize_snapshot(snapshot),
         true <-
           MapSet.new(Map.keys(normalized)) == @policy_snapshot_keys ||
             {:error, :target_policy_changed},
         true <-
           normalized["schema"] == @policy_schema ||
             {:error, :target_policy_changed},
         true <- normalized["action"] == @action || {:error, :target_policy_changed},
         true <-
           to_string(normalized["binding_id"]) == to_string(value(binding, :id)) ||
             {:error, :target_policy_changed},
         true <-
           normalized["binding_version"] == value(binding, :binding_version) ||
             {:error, :target_policy_changed},
         true <-
           normalized["version"] == policy_version(binding) ||
             {:error, :target_policy_changed},
         true <-
           to_string(normalized["approval_id"]) == to_string(value(binding, :approval_id)) ||
             {:error, :target_policy_changed},
         true <-
           normalized["approval_state"] in [:approved, "approved"] ||
             {:error, :target_policy_changed},
         true <-
           normalized["approval_expires_at"] ==
             iso8601(value(binding, :approval_expires_at)) ||
             {:error, :target_policy_changed} do
      {:ok, snapshot}
    else
      false -> {:error, :target_policy_changed}
      {:error, _} -> {:error, :target_policy_changed}
    end
  end

  defp policy_version(binding),
    do: value(value(binding, :review_metadata) || %{}, :policy_version)

  defp authorization_version(:human, _principal, owner, profile, permissions) do
    Targeting.snapshot_digest(%{
      "actor_id" => value(owner, :id),
      "actor_status" => to_string(value(owner, :status)),
      "actor_role" => to_string(value(owner, :role)),
      "actor_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_id" => value(profile, :id),
      "profile_updated_at" => iso8601(value(profile, :updated_at)),
      "fresh_permissions" => permissions
    })
  end

  defp authorization_version(:service_principal, principal, owner, profile, permissions) do
    Targeting.snapshot_digest(%{
      "schema" => "serviceradar.service_principal_authorization.v1",
      "service_principal_id" => value(principal, :id),
      "service_principal_owner_id" => value(owner, :id),
      "service_principal_updated_at" => iso8601(value(principal, :updated_at)),
      "service_principal_scopes" => principal |> value(:scopes) |> List.wrap() |> Enum.sort(),
      "owner_status" => to_string(value(owner, :status)),
      "owner_role" => to_string(value(owner, :role)),
      "owner_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_id" => value(profile, :id),
      "profile_updated_at" => iso8601(value(profile, :updated_at)),
      "fresh_permissions" => permissions
    })
  end

  defp service_principal_active?(principal, owner_id, grant, now) do
    expires_at = value(principal, :expires_at)

    value(principal, :enabled) == true and is_nil(value(principal, :revoked_at)) and
      (is_nil(expires_at) or future?(expires_at, now)) and
      to_string(value(principal, :user_id)) == to_string(owner_id) and
      to_string(owner_id) == to_string(value(grant, :principal_owner_id))
  end

  defp service_principal_write_scope?(principal) do
    scopes = principal |> value(:scopes) |> List.wrap()
    "write" in scopes or "admin" in scopes
  end

  defp target_membership_ids(grant) do
    grant
    |> value(:awx_scope_snapshot)
    |> value(:targets)
    |> List.wrap()
    |> Enum.map(&(&1 |> value(:membership_id) |> to_string()))
  end

  defp exact_nonempty_ids(ids) when is_list(ids) and ids != [] do
    normalized = Enum.map(ids, &optional_string/1)

    if Enum.all?(normalized, &(is_binary(&1) and &1 != "")) and
         Enum.uniq(normalized) == normalized,
       do: :ok,
       else: {:error, :target_no_longer_authorized}
  end

  defp exact_nonempty_ids(_ids), do: {:error, :target_no_longer_authorized}

  defp operation_run_state(:planned), do: :authorized
  defp operation_run_state(:dispatching), do: :pending
  defp operation_run_state(:running), do: :running
  defp operation_run_state(_), do: :inactive

  defp execution_job_state(state) when state in [:launching], do: :pending
  defp execution_job_state(state) when state in [:scope_verified, :running], do: :running
  defp execution_job_state(_), do: :inactive

  defp source(context) when is_map(context),
    do: Map.get(context, :source) || Map.get(context, "source") || CurrentAuthorityAshSource

  defp source(context) when is_list(context),
    do: Keyword.get(context, :source, CurrentAuthorityAshSource)

  defp source(_context), do: CurrentAuthorityAshSource

  defp now(context) when is_map(context),
    do: Map.get(context, :now) || Map.get(context, "now") || DateTime.utc_now()

  defp now(context) when is_list(context), do: Keyword.get(context, :now, DateTime.utc_now())
  defp now(_context), do: DateTime.utc_now()

  defp future?(%DateTime{} = value, %DateTime{} = now), do: DateTime.after?(value, now)
  defp future?(_value, _now), do: false

  defp bounded_approval_issued_at(snapshot_issued_at, %DateTime{} = grant_issued_at, now) do
    age_seconds = DateTime.diff(grant_issued_at, snapshot_issued_at, :second)

    if age_seconds in 0..@max_approval_snapshot_age_seconds and
         not DateTime.after?(grant_issued_at, now),
       do: :ok,
       else: {:error, :approval_changed}
  end

  defp bounded_approval_issued_at(_snapshot_issued_at, _grant_issued_at, _now),
    do: {:error, :approval_changed}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :approval_changed}
    end
  end

  defp parse_datetime(_value), do: {:error, :approval_changed}

  defp normalize_snapshot(snapshot) when is_map(snapshot) and map_size(snapshot) > 0 do
    Enum.reduce_while(snapshot, {:ok, %{}}, fn {key, nested}, {:ok, normalized} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, {:error, :invalid_authorization_snapshot}}
        Map.has_key?(normalized, key) -> {:halt, {:error, :invalid_authorization_snapshot}}
        true -> {:cont, {:ok, Map.put(normalized, key, nested)}}
      end
    end)
  end

  defp normalize_snapshot(_snapshot), do: {:error, :invalid_authorization_snapshot}

  defp canonical_equal?(left, right) do
    with {:ok, left_digest} <- CanonicalJSON.digest(left),
         {:ok, right_digest} <- CanonicalJSON.digest(right) do
      secure_equal(left_digest, right_digest)
    else
      _ -> false
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp blank?(value), do: is_nil(value) or value == ""

  defp normalize_principal_type(value) when value in [:human, "human"], do: :human

  defp normalize_principal_type(value) when value in [:service_principal, "service_principal"],
    do: :service_principal

  defp normalize_principal_type(_value), do: :unknown

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil
  defp iso8601(value), do: to_string(value)

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
