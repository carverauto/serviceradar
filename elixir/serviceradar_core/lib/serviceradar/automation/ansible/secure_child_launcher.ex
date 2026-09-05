defmodule ServiceRadar.Automation.Ansible.SecureChildLauncher do
  @moduledoc """
  Authorizes, snapshots, persists, and dispatches one exact AWX child execution.

  The public request contains durable AWX membership IDs, never host names,
  addresses, device metadata, or an Ansible limit. Every mutable resource is
  reloaded before planning. The resulting authority ceiling is attenuated to
  the source-controlled action permissions and exact membership IDs in this
  child.

  This service intentionally accepts only a current human actor. Scheduled and
  northbound execution must use a separately reviewed delegation path rather
  than substituting a `SystemActor` for the initiating principal.

  Callback-enabled bindings use only their immutable reviewed launch contract.
  No bearer, callback endpoint, callback phase, or callback policy is accepted
  in launch inputs.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.HardenedLaunchPlan
  alias ServiceRadar.Automation.Ansible.LiveAwxLaunchPreflight
  alias ServiceRadar.Automation.Ansible.SecureChildLauncher.AshAdapter
  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.LaunchContract
  alias ServiceRadar.Edge.AgentCommandBus

  @launch_permission "ansible.runs.launch"
  @max_targets 500
  @request_source ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/
  @forbidden_request_keys MapSet.new([
                            "ansible_host",
                            "api_key",
                            "authorization",
                            "bearer_token",
                            "allowed_callback_origin",
                            "allowed_origin",
                            "callback_manifest_sha256",
                            "callback_operation",
                            "callback_origin",
                            "callback_phase",
                            "callback_policy",
                            "callback_response_policy_provider",
                            "callback_state",
                            "callback_url",
                            "desired_state",
                            "device_uid",
                            "device_uids",
                            "extra_vars",
                            "host",
                            "host_limit",
                            "hostname",
                            "limit",
                            "manifest_sha256",
                            "operation",
                            "phase",
                            "public_policy",
                            "remote_access_operation",
                            "response_policy_provider",
                            "state"
                          ])

  @type request :: %{
          required(:actor) => map(),
          required(:membership_ids) => [String.t()],
          required(:playbook_id) => String.t(),
          required(:job_template_id) => pos_integer(),
          required(:mode) => :run | :check,
          required(:inputs) => map(),
          required(:request_source) => String.t() | atom()
        }

  @doc "Launches one controller/inventory-bound child through the hardened path."
  @spec launch(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def launch(request, opts \\ [])

  def launch(request, opts) when is_map(request) and is_list(opts) do
    adapter = Keyword.get(opts, :adapter, AshAdapter)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- validate_request(request),
         {:ok, preflight_state} <- load_launch_state(normalized, adapter, now),
         {:ok, dispatcher_identity} <-
           authenticated_edge_principal(preflight_state.controller, opts),
         {:ok, preflight_attestation} <-
           attest_live_preflight(preflight_state, dispatcher_identity, now, opts),
         post_preflight_now = Keyword.get(opts, :post_preflight_now, now),
         {:ok, launch_state} <- load_launch_state(normalized, adapter, post_preflight_now),
         actor_snapshot =
           actor_snapshot(
             launch_state.current_actor,
             launch_state.authorization,
             normalized.membership_ids,
             launch_state.binding,
             launch_state.callback_contract,
             post_preflight_now
           ),
         {:ok, plan} <-
           HardenedLaunchPlan.build(%{
             action: action(normalized.mode),
             request_source: normalized.request_source,
             mode: normalized.mode,
             mutating: normalized.mode == :run,
             controller_id: launch_state.scope.controller_id,
             controller_security_snapshot: launch_state.controller_security_snapshot,
             job_template_id: normalized.job_template_id,
             actor_snapshot: actor_snapshot,
             memberships: launch_state.memberships,
             held_device_uids: launch_state.held_device_uids,
             binding: launch_state.launch_binding,
             preflight_binding: launch_state.binding,
             preflight_attestation: preflight_attestation,
             preflight_checked_at: post_preflight_now,
             variable_schema: launch_state.variable_schema,
             inputs: normalized.inputs,
             callback_gate_available: not is_nil(launch_state.callback_contract),
             callback_contract: launch_state.callback_contract,
             dynamic_callback_slot:
               if(
                 launch_state.callback_contract,
                 do: launch_state.launch_binding.callback_credential_slot
               )
           }) do
      adapter.launch(plan, launch_state.controller)
    end
  end

  def launch(_request, _opts), do: {:error, :invalid_secure_launch_request}

  # Every launch takes this read-only state snapshot twice: once to construct
  # the exact preflight request, then again after the edge response and before
  # any mutable operation/execution is created. The second read is not an
  # optimization barrier; it is the authority-contraction boundary.
  defp load_launch_state(normalized, adapter, now) do
    with {:ok, current_actor} <- adapter.load_current_actor(normalized.actor_id),
         :ok <- validate_current_actor(current_actor, normalized.actor_id),
         {:ok, authorization} <- adapter.fresh_authorization(current_actor),
         :ok <- require_launch_permission(authorization),
         {:ok, playbook} <- adapter.load_playbook(normalized.playbook_id),
         :ok <- validate_playbook(playbook, normalized),
         {:ok, memberships} <- adapter.load_memberships(normalized.membership_ids),
         {:ok, scope} <- validate_membership_scope(memberships, normalized, playbook),
         {:ok, controller} <- adapter.load_controller(scope.controller_id),
         :ok <- validate_controller(controller, scope.controller_id),
         {:ok, controller_security_snapshot} <- ControllerSecuritySnapshot.capture(controller),
         {:ok, binding} <- adapter.load_binding(scope.controller_id, normalized.job_template_id),
         {:ok, launch_binding, callback_contract} <-
           validate_binding(
             binding,
             scope,
             normalized.job_template_id,
             normalized.mode,
             now
           ),
         :ok <- require_action_permissions(authorization, callback_contract),
         {:ok, held_device_uids} <- adapter.active_hold_device_uids(scope.device_uids),
         :ok <- reject_active_holds(held_device_uids, scope.device_uids),
         {:ok, variable_schema} <- VariableSchema.from_binding(binding) do
      {:ok,
       %{
         current_actor: current_actor,
         authorization: authorization,
         memberships: memberships,
         scope: scope,
         controller: controller,
         controller_security_snapshot: controller_security_snapshot,
         binding: binding,
         launch_binding: launch_binding,
         callback_contract: callback_contract,
         held_device_uids: held_device_uids,
         variable_schema: variable_schema
       }}
    end
  end

  defp attest_live_preflight(state, dispatcher_identity, now, opts) do
    preflight = Keyword.get(opts, :live_preflight, LiveAwxLaunchPreflight)

    preflight_opts =
      opts
      |> Keyword.get(:live_preflight_opts, [])
      |> normalize_preflight_opts(now)

    context = %{
      controller: state.controller,
      binding: state.binding,
      memberships: state.memberships,
      controller_security_snapshot: state.controller_security_snapshot,
      dispatcher_identity: dispatcher_identity
    }

    case preflight do
      fun when is_function(fun, 2) -> fun.(context, preflight_opts)
      module when is_atom(module) -> apply(module, :attest, [context, preflight_opts])
      _ -> {:error, :awx_preflight_unavailable}
    end
  rescue
    UndefinedFunctionError -> {:error, :awx_preflight_unavailable}
  end

  defp normalize_preflight_opts(options, now) when is_list(options) do
    options = if Keyword.keyword?(options), do: options, else: []
    Keyword.put_new(options, :clock, fn -> now end)
  end

  defp normalize_preflight_opts(_options, now), do: [clock: fn -> now end]

  defp authenticated_edge_principal(controller, opts) do
    resolver =
      Keyword.get(
        opts,
        :edge_principal_resolver,
        &AgentCommandBus.resolve_control_session_evidence/1
      )

    with true <- is_function(resolver, 1),
         {:ok, evidence} when is_map(evidence) <- resolver.(value(controller, :agent_id)),
         agent_id when is_binary(agent_id) <- value(evidence, :agent_id),
         true <- agent_id == value(controller, :agent_id),
         partition_id when is_binary(partition_id) <- value(evidence, :partition_id),
         partition_id = String.trim(partition_id),
         true <- partition_id != "" do
      {:ok, %{agent_id: agent_id, partition_id: partition_id}}
    else
      _ -> {:error, :authenticated_edge_principal_unavailable}
    end
  end

  defp validate_request(request) do
    actor = value(request, :actor)
    actor_id = value(actor, :id)
    membership_ids = value(request, :membership_ids)
    playbook_id = value(request, :playbook_id)
    job_template_id = value(request, :job_template_id)
    mode = value(request, :mode)
    inputs = value(request, :inputs)

    with :ok <- reject_raw_scope_and_policy(request),
         :ok <- initial_human_actor(actor, actor_id),
         {:ok, actor_id} <- canonical_uuid(actor_id, :actor_required),
         {:ok, membership_ids} <- exact_membership_ids(membership_ids),
         {:ok, playbook_id} <- canonical_uuid(playbook_id, :playbook_required),
         :ok <- positive_integer(job_template_id, :job_template_required),
         :ok <- launch_mode(mode),
         :ok <- inputs_map(inputs),
         {:ok, request_source} <- request_source(value(request, :request_source)) do
      {:ok,
       %{
         actor_id: actor_id,
         membership_ids: membership_ids,
         playbook_id: playbook_id,
         job_template_id: job_template_id,
         mode: mode,
         inputs: inputs,
         request_source: request_source
       }}
    end
  end

  defp initial_human_actor(actor, actor_id) do
    cond do
      not is_map(actor) ->
        {:error, :human_actor_required}

      SystemActor.system_actor?(actor) ->
        {:error, :human_actor_required}

      value(actor, :role) in [:system, "system"] ->
        {:error, :human_actor_required}

      is_binary(actor_id) and String.starts_with?(actor_id, "system:") ->
        {:error, :human_actor_required}

      true ->
        :ok
    end
  end

  defp reject_raw_scope_and_policy(request) do
    forbidden =
      request
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&MapSet.member?(@forbidden_request_keys, &1))
      |> Enum.sort()

    if forbidden == [],
      do: :ok,
      else: {:error, {:raw_launch_scope_or_policy_forbidden, forbidden}}
  end

  defp exact_membership_ids(ids)
       when is_list(ids) and ids != [] and length(ids) <= @max_targets do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case canonical_uuid(id, :invalid_membership_id) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, canonical_ids} ->
        canonical_ids = Enum.reverse(canonical_ids)

        if length(canonical_ids) == length(Enum.uniq(canonical_ids)),
          do: {:ok, canonical_ids},
          else: {:error, :duplicate_membership_id}

      error ->
        error
    end
  end

  defp exact_membership_ids([]), do: {:error, :memberships_required}
  defp exact_membership_ids(ids) when is_list(ids), do: {:error, :too_many_memberships}
  defp exact_membership_ids(_), do: {:error, :memberships_required}

  defp validate_current_actor(actor, requested_id) when is_map(actor) do
    with {:ok, current_id} <- canonical_uuid(value(actor, :id), :actor_identity_drift) do
      cond do
        current_id != requested_id -> {:error, :actor_identity_drift}
        SystemActor.system_actor?(actor) -> {:error, :human_actor_required}
        value(actor, :role) in [:system, "system"] -> {:error, :human_actor_required}
        value(actor, :status) not in [:active, "active"] -> {:error, :actor_inactive}
        true -> :ok
      end
    end
  end

  defp validate_current_actor(_actor, _requested_id), do: {:error, :actor_not_found}

  defp require_launch_permission(%{permissions: %MapSet{} = permissions}) do
    if MapSet.member?(permissions, @launch_permission),
      do: :ok,
      else: {:error, :launch_permission_required}
  end

  defp require_launch_permission(_), do: {:error, :fresh_authorization_required}

  defp validate_playbook(playbook, request) when is_map(playbook) do
    with {:ok, id} <- canonical_uuid(value(playbook, :id), :playbook_identity_drift) do
      cond do
        id != request.playbook_id ->
          {:error, :playbook_identity_drift}

        value(playbook, :source_type) not in [:awx, "awx"] ->
          {:error, :awx_playbook_required}

        value(playbook, :parse_status) not in [:ok, "ok"] ->
          {:error, :playbook_not_launchable}

        value(playbook, :awx_job_template_id) != request.job_template_id ->
          {:error, :playbook_template_drift}

        not uuid?(value(playbook, :controller_id)) ->
          {:error, :playbook_controller_required}

        true ->
          :ok
      end
    end
  end

  defp validate_playbook(_playbook, _request), do: {:error, :playbook_not_found}

  defp validate_membership_scope(memberships, request, playbook) when is_list(memberships) do
    requested = MapSet.new(request.membership_ids)

    with {:ok, loaded_ids} <- membership_ids(memberships),
         :ok <- exact_loaded_memberships(requested, loaded_ids),
         {:ok, controller_id} <- one_value(memberships, :controller_id, :controller_drift),
         {:ok, controller_id} <- canonical_uuid(controller_id, :controller_drift),
         {:ok, inventory_id} <- one_positive_value(memberships, :inventory_id, :inventory_drift),
         :ok <- playbook_controller(playbook, controller_id),
         {:ok, device_uids} <- exact_device_uids(memberships) do
      {:ok,
       %{
         controller_id: controller_id,
         inventory_id: inventory_id,
         device_uids: device_uids
       }}
    end
  end

  defp validate_membership_scope(_memberships, _request, _playbook),
    do: {:error, :membership_lookup_failed}

  defp membership_ids(memberships) do
    memberships
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, acc} ->
      with true <- is_map(membership) or {:error, :membership_lookup_failed},
           {:ok, id} <- canonical_uuid(value(membership, :id), :membership_identity_drift) do
        {:cont, {:ok, [id | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} ->
        if length(ids) == length(Enum.uniq(ids)),
          do: {:ok, Enum.reverse(ids)},
          else: {:error, :membership_identity_drift}

      error ->
        error
    end
  end

  defp exact_loaded_memberships(requested, loaded_ids) do
    if MapSet.equal?(requested, MapSet.new(loaded_ids)),
      do: :ok,
      else: {:error, :membership_set_drift}
  end

  defp exact_device_uids(memberships) do
    memberships
    |> Enum.map(&value(&1, :canonical_device_uid))
    |> case do
      uids ->
        if Enum.all?(uids, &nonempty_string?/1),
          do: {:ok, Enum.sort(Enum.uniq(uids))},
          else: {:error, :membership_device_link_required}
    end
  end

  defp playbook_controller(playbook, controller_id) do
    case Ecto.UUID.cast(value(playbook, :controller_id)) do
      {:ok, ^controller_id} -> :ok
      _ -> {:error, :playbook_controller_drift}
    end
  end

  defp validate_controller(controller, expected_id) when is_map(controller) do
    with {:ok, id} <- canonical_uuid(value(controller, :id), :controller_identity_drift) do
      cond do
        id != expected_id -> {:error, :controller_identity_drift}
        value(controller, :enabled) != true -> {:error, :controller_disabled}
        true -> :ok
      end
    end
  end

  defp validate_controller(_controller, _expected_id), do: {:error, :controller_not_found}

  defp validate_binding(binding, scope, job_template_id, mode, now) when is_map(binding) do
    allowed_inventory_ids = List.wrap(value(binding, :allowed_inventory_ids))
    callback_actions = List.wrap(value(binding, :callback_actions))

    with :ok <- binding_identity(binding, scope.controller_id, job_template_id),
         :ok <- binding_approval(binding, now),
         :ok <- binding_inventory(allowed_inventory_ids, scope.inventory_id),
         :ok <- binding_mode(binding, mode),
         {:ok, dispatch_marker_contract} <-
           DispatchMarkerContract.from_review_metadata(value(binding, :review_metadata)),
         {:ok, callback_contract} <- callback_contract(binding, callback_actions),
         {:ok, credential_ids} <- credential_ids(value(binding, :credentials)) do
      {:ok,
       %{
         approval_state: "approved",
         inventory_id: scope.inventory_id,
         inventory_group_names: List.wrap(value(binding, :inventory_group_names)),
         ask_limit_on_launch: value(binding, :ask_limit_on_launch),
         ask_credential_on_launch: value(binding, :ask_credential_on_launch),
         dispatch_markers_retained: value(binding, :dispatch_markers_retained),
         dispatch_marker_contract: dispatch_marker_contract,
         project_update_on_launch: value(binding, :project_update_on_launch),
         project_id: value(binding, :project_id),
         scm_revision: value(binding, :scm_revision),
         content_sha256: value(binding, :content_sha256),
         execution_environment_id: value(binding, :execution_environment_id),
         credential_ids: credential_ids,
         credentials: value(binding, :credentials),
         machine_credential_id: value(binding, :machine_credential_id),
         job_type: Atom.to_string(mode),
         awx_created_by_id: value(binding, :awx_created_by_id),
         input_classifications: value(binding, :input_classifications),
         callback_actions: callback_actions,
         callback_credential_type_id: value(binding, :callback_credential_type_id),
         callback_credential_organization_id:
           value(binding, :callback_credential_organization_id),
         callback_credential_injector_digest:
           value(binding, :callback_credential_injector_digest),
         callback_credential_slot: value(binding, :callback_credential_slot)
       }, callback_contract}
    end
  end

  defp validate_binding(_binding, _scope, _job_template_id, _mode, _now),
    do: {:error, :binding_not_found}

  defp binding_identity(binding, controller_id, job_template_id) do
    with {:ok, actual_controller_id} <-
           canonical_uuid(value(binding, :controller_id), :binding_controller_drift) do
      cond do
        not uuid?(value(binding, :id)) ->
          {:error, :binding_identity_drift}

        actual_controller_id != controller_id ->
          {:error, :binding_controller_drift}

        value(binding, :job_template_id) != job_template_id ->
          {:error, :binding_template_drift}

        value(binding, :current) != true ->
          {:error, :binding_not_current}

        not positive_integer?(value(binding, :binding_version)) ->
          {:error, :binding_version_required}

        true ->
          :ok
      end
    end
  end

  defp binding_approval(binding, now) do
    expires_at = value(binding, :approval_expires_at)

    cond do
      value(binding, :approval_state) not in [:approved, "approved"] ->
        {:error, :binding_not_approved}

      not uuid?(value(binding, :approval_id)) ->
        {:error, :binding_approval_required}

      not match?(%DateTime{}, expires_at) ->
        {:error, :binding_approval_expired}

      DateTime.compare(expires_at, now) != :gt ->
        {:error, :binding_approval_expired}

      true ->
        :ok
    end
  end

  defp binding_inventory(allowed, inventory_id) do
    if inventory_id in allowed,
      do: :ok,
      else: {:error, :binding_inventory_drift}
  end

  defp binding_mode(binding, :run) do
    if value(binding, :run_mode_supported) == true,
      do: :ok,
      else: {:error, :binding_mode_not_approved}
  end

  defp binding_mode(binding, :check) do
    if value(binding, :check_mode_supported) == true,
      do: :ok,
      else: {:error, :binding_mode_not_approved}
  end

  defp callback_contract(_binding, []), do: {:ok, nil}

  defp callback_contract(binding, _actions), do: LaunchContract.from_binding(binding)

  defp credential_ids(credentials) when is_list(credentials) and credentials != [] do
    ids = Enum.map(credentials, &value(&1, :id))

    if Enum.all?(ids, &positive_integer?/1) and length(ids) == length(Enum.uniq(ids)),
      do: {:ok, Enum.sort(ids)},
      else: {:error, :binding_credentials_required}
  end

  defp credential_ids(_credentials), do: {:error, :binding_credentials_required}

  defp reject_active_holds(held_device_uids, requested_device_uids)
       when is_list(held_device_uids) do
    held = MapSet.new(held_device_uids)
    requested = MapSet.new(requested_device_uids)

    case requested |> MapSet.intersection(held) |> MapSet.to_list() |> Enum.sort() do
      [] -> :ok
      [device_uid | _] -> {:error, {:target_held, device_uid}}
    end
  end

  defp reject_active_holds(_held_device_uids, _requested_device_uids),
    do: {:error, :target_hold_lookup_failed}

  defp actor_snapshot(actor, authorization, membership_ids, binding, callback_contract, now) do
    permissions = authorization.permissions |> MapSet.to_list() |> Enum.sort()

    authorization_basis = %{
      "actor_id" => value(actor, :id),
      "actor_status" => to_string(value(actor, :status)),
      "actor_role" => to_string(value(actor, :role)),
      "actor_updated_at" => iso8601(value(actor, :updated_at)),
      "profile_versions" => profile_versions(value(authorization, :profile_versions)),
      "fresh_permissions" => permissions
    }

    %{
      principal_type: :human,
      principal_id: value(actor, :id),
      tenant_id: value(actor, :tenant_id) || "platform",
      authorization_version: Targeting.snapshot_digest(authorization_basis),
      authority_ceiling: %{
        "permissions" => required_permissions(callback_contract),
        "target_membership_ids" => Enum.sort(membership_ids)
      },
      approval_snapshot: approval_snapshot(binding, now)
    }
  end

  defp profile_versions(versions) when is_list(versions) do
    versions
    |> Enum.map(fn version ->
      {to_string(value(version, :id)), iso8601(value(version, :updated_at))}
    end)
    |> Enum.sort()
  end

  defp profile_versions(_versions), do: []

  defp require_action_permissions(_authorization, nil), do: :ok

  defp require_action_permissions(%{permissions: %MapSet{} = permissions}, contract) do
    missing =
      contract
      |> required_permissions()
      |> Enum.reject(&MapSet.member?(permissions, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:callback_permissions_required, missing}}
  end

  defp require_action_permissions(_authorization, _contract),
    do: {:error, :fresh_authorization_required}

  defp required_permissions(nil), do: [@launch_permission]

  defp required_permissions(contract) do
    case ActionContract.fetch(contract.action) do
      {:ok, action_contract} -> ActionContract.required_permissions(action_contract)
      {:error, _reason} -> []
    end
  end

  defp approval_snapshot(binding, now) do
    %{
      "binding_id" => value(binding, :id),
      "binding_version" => value(binding, :binding_version),
      "approval_id" => value(binding, :approval_id),
      "approval_expires_at" => iso8601(value(binding, :approval_expires_at)),
      "reviewed_by_principal_type" => value(binding, :reviewed_by_principal_type),
      "reviewed_by_principal_id" => value(binding, :reviewed_by_principal_id),
      "reviewed_at" => iso8601(value(binding, :reviewed_at)),
      "review_metadata" => value(binding, :review_metadata) || %{},
      "issued_at" => iso8601(now)
    }
  end

  defp one_value(values, key, error) do
    case values |> Enum.map(&value(&1, key)) |> Enum.uniq() do
      [single] -> {:ok, single}
      _ -> {:error, error}
    end
  end

  defp one_positive_value(values, key, error) do
    with {:ok, single} <- one_value(values, key, error),
         true <- positive_integer?(single) do
      {:ok, single}
    else
      _ -> {:error, error}
    end
  end

  defp canonical_uuid(value, error) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp canonical_uuid(_value, error), do: {:error, error}

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, error), do: {:error, error}
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp launch_mode(mode) when mode in [:run, :check], do: :ok
  defp launch_mode(_mode), do: {:error, :invalid_launch_mode}

  defp inputs_map(inputs) when is_map(inputs), do: :ok
  defp inputs_map(_inputs), do: {:error, :invalid_launch_inputs}

  defp request_source(source) when is_atom(source), do: request_source(Atom.to_string(source))

  defp request_source(source) when is_binary(source) do
    if Regex.match?(@request_source, source),
      do: {:ok, source},
      else: {:error, :invalid_request_source}
  end

  defp request_source(_source), do: {:error, :invalid_request_source}

  defp action(:run), do: "ansible.playbook.run"
  defp action(:check), do: "ansible.playbook.check"

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil
  defp iso8601(value), do: to_string(value)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
