defmodule ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority do
  @moduledoc """
  Reconstructs current authority for one persisted non-callback AWX execution.

  The immutable operation, execution, and target rows are ceilings, not proof
  that authority is still current. Immediately before dispatch this module
  reloads the initiating principal and role profile, every exact membership,
  the reviewed template binding, and target holds. It then intersects those
  current facts with the frozen actor, approval, target, and binding snapshot
  immediately before launch and every known-child continuation.
  """

  alias ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.AshSource
  alias ServiceRadar.Automation.Ansible.Targeting

  @launch_permission "ansible.runs.launch"
  @source_fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
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
  @max_approval_snapshot_age_seconds 300

  @spec authorize_launch(map(), DateTime.t(), keyword() | map()) :: :ok | {:error, term()}
  def authorize_launch(resources, now, context \\ [])

  def authorize_launch(resources, %DateTime{} = now, context) do
    authorize_attempt(
      %{stage: :launch_job, purpose: :accepted_job_proof},
      resources,
      now,
      context
    )
  end

  def authorize_launch(_resources, _now, _context), do: {:error, :current_authority_required}

  @spec authorize_attempt(map() | struct(), map(), DateTime.t(), keyword() | map()) ::
          :ok | {:error, term()}
  def authorize_attempt(attempt, resources, now, context \\ [])

  def authorize_attempt(
        attempt,
        %{operation: operation, execution: execution, targets: targets},
        %DateTime{} = now,
        context
      )
      when is_map(attempt) and is_map(operation) and is_map(execution) and is_list(targets) do
    source = source(context)
    principal_type = normalize_principal_type(value(operation, :initiator_principal_type))
    principal_id = optional_string(value(operation, :initiator_principal_id))
    owner_id = optional_string(value(operation, :service_principal_owner_id))
    membership_ids = Enum.map(targets, &optional_string(value(&1, :membership_id)))

    with {:ok, phase} <- authority_phase(attempt),
         true <- principal_type in [:human, :service_principal] || {:error, :principal_changed},
         :ok <- exact_nonempty_ids(membership_ids),
         {:ok, principal_data} <-
           source.load_principal(principal_type, principal_id, owner_id),
         {:ok, memberships} <- source.load_memberships(membership_ids),
         {:ok, binding} <-
           source.load_current_binding(
             value(execution, :controller_id),
             value(execution, :job_template_id)
           ),
         {:ok, principal} <-
           current_principal(operation, principal_type, principal_data, now),
         :ok <- exact_operation(operation, execution, targets, principal, phase),
         :ok <- exact_execution(operation, execution, phase),
         :ok <- current_binding(operation, execution, binding, now, phase),
         {:ok, current_targets} <- current_targets(operation, execution, targets, memberships),
         {:ok, holds} <- source.active_holds(Enum.map(current_targets, & &1.device_uid)),
         true <- holds == [] || {:error, :target_policy_changed} do
      :ok
    else
      false -> {:error, :current_authority_required}
      {:error, _reason} = error -> error
      _ -> {:error, :current_authority_required}
    end
  rescue
    _ -> {:error, :current_authority_required}
  catch
    _, _ -> {:error, :current_authority_required}
  end

  def authorize_attempt(_attempt, _resources, _now, _context),
    do: {:error, :current_authority_required}

  defp current_principal(
         operation,
         type,
         %{principal: principal, owner: owner, authority: authority},
         now
       ) do
    permissions =
      authority |> value(:permissions) |> MapSet.new() |> Enum.map(&to_string/1) |> Enum.sort()

    profile_versions = profile_versions(value(authority, :profile_versions))

    required_permissions =
      operation
      |> value(:authority_ceiling)
      |> value(:permissions)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.sort()
      |> Enum.uniq()

    principal_id = if type == :human, do: value(owner, :id), else: value(principal, :id)
    owner_id = if type == :service_principal, do: value(owner, :id)

    with true <- value(owner, :status) in [:active, "active"] || {:error, :principal_disabled},
         true <-
           to_string(principal_id) == to_string(value(operation, :initiator_principal_id)) ||
             {:error, :principal_changed},
         true <-
           optional_string(value(owner, :tenant_id) || "platform") ==
             optional_string(value(operation, :tenant_id)) || {:error, :tenant_changed},
         true <-
           (type != :service_principal or
              service_principal_active?(principal, owner_id, operation, now)) ||
             {:error, :principal_disabled},
         true <-
           (required_permissions != [] and @launch_permission in required_permissions and
              Enum.all?(required_permissions, &(&1 in permissions))) ||
             {:error, :current_permission_denied},
         authorization_version = to_string(value(operation, :authorization_version)),
         true <-
           authorization_version_matches?(
             authorization_version,
             type,
             principal,
             owner,
             profile_versions,
             permissions
           ) || {:error, :principal_changed} do
      {:ok,
       %{
         type: type,
         id: to_string(principal_id),
         owner_id: optional_string(owner_id),
         permissions: permissions,
         authorization_version: authorization_version
       }}
    else
      false -> {:error, :principal_changed}
      {:error, _reason} = error -> error
    end
  end

  defp current_principal(_operation, _type, _principal_data, _now),
    do: {:error, :current_authority_required}

  defp exact_operation(operation, execution, targets, principal, phase) do
    ceiling = value(operation, :authority_ceiling) || %{}

    ceiling_memberships =
      ceiling
      |> value(:target_membership_ids)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    target_memberships =
      targets |> Enum.map(&(&1 |> value(:membership_id) |> to_string())) |> Enum.sort()

    expected_action =
      if value(execution, :check_mode) == true,
        do: "ansible.playbook.check",
        else: "ansible.playbook.run"

    cond do
      value(operation, :state) != operation_state(phase) ->
        {:error, :run_not_active}

      List.wrap(value(operation, :callback_actions)) != [] ->
        {:error, :callback_execution_isolated}

      to_string(value(operation, :action)) != expected_action ->
        {:error, :action_no_longer_authorized}

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

      ceiling_memberships == [] or ceiling_memberships != target_memberships ->
        {:error, :target_no_longer_authorized}

      length(target_memberships) != length(Enum.uniq(target_memberships)) ->
        {:error, :target_no_longer_authorized}

      true ->
        :ok
    end
  end

  defp exact_execution(operation, execution, phase) do
    operation_snapshot = value(value(operation, :metadata) || %{}, :snapshot_digest)

    cond do
      to_string(value(execution, :operation_id)) != to_string(value(operation, :id)) ->
        {:error, :run_not_active}

      value(execution, :state) != execution_state(phase) ->
        {:error, :job_not_active}

      not secure_equal(
        to_string(operation_snapshot),
        to_string(value(execution, :snapshot_digest))
      ) ->
        {:error, :awx_binding_changed}

      true ->
        :ok
    end
  end

  defp current_binding(operation, execution, binding, now, phase) do
    snapshot = stringify(value(operation, :approval_snapshot) || %{})
    binding_credentials = normalize_credentials(value(binding, :credentials))

    execution_credentials =
      execution
      |> value(:credential_snapshot)
      |> value(:credentials)
      |> normalize_credentials()

    execution_credential_ids =
      execution
      |> value(:credential_snapshot)
      |> value(:credential_ids)
      |> List.wrap()
      |> Enum.sort()

    binding_credential_ids =
      case binding_credentials do
        credentials when is_list(credentials) -> Enum.map(credentials, & &1["id"])
        _ -> []
      end

    with :ok <- exact_approval_snapshot(snapshot, binding, now, phase) do
      cond do
        value(binding, :current) != true ->
          {:error, :awx_binding_changed}

        value(binding, :approval_state) not in [:approved, "approved"] ->
          {:error, :approval_changed}

        to_string(value(binding, :controller_id)) != to_string(value(execution, :controller_id)) ->
          {:error, :awx_binding_changed}

        value(binding, :job_template_id) != value(execution, :job_template_id) ->
          {:error, :awx_binding_changed}

        value(execution, :inventory_id) not in List.wrap(value(binding, :allowed_inventory_ids)) ->
          {:error, :awx_binding_changed}

        value(binding, :project_update_on_launch) != false or
          value(binding, :ask_limit_on_launch) != true or
            value(binding, :dispatch_markers_retained) != true ->
          {:error, :awx_binding_changed}

        value(binding, :project_id) != value(execution, :project_id) or
          value(binding, :scm_revision) != value(execution, :scm_revision) or
          value(binding, :content_sha256) != value(execution, :content_sha256) or
          value(binding, :execution_environment_id) !=
            value(execution, :execution_environment_id) or
            value(binding, :machine_credential_id) != value(execution, :machine_credential_id) ->
          {:error, :awx_binding_changed}

        binding_credentials == :invalid or execution_credentials == :invalid or
          binding_credentials != execution_credentials or
            binding_credential_ids != execution_credential_ids ->
          {:error, :awx_binding_changed}

        value(execution, :check_mode) == true and value(binding, :check_mode_supported) != true ->
          {:error, :action_no_longer_authorized}

        value(execution, :check_mode) != true and value(binding, :run_mode_supported) != true ->
          {:error, :action_no_longer_authorized}

        List.wrap(value(binding, :callback_actions)) != [] ->
          {:error, :callback_execution_isolated}

        true ->
          :ok
      end
    end
  end

  defp exact_approval_snapshot(snapshot, binding, now, phase) do
    with true <-
           MapSet.new(Map.keys(snapshot)) == @approval_snapshot_keys ||
             {:error, :approval_changed},
         true <-
           to_string(snapshot["binding_id"]) == to_string(value(binding, :id)) ||
             {:error, :approval_changed},
         true <-
           snapshot["binding_version"] == value(binding, :binding_version) ||
             {:error, :approval_changed},
         true <-
           to_string(snapshot["approval_id"]) == to_string(value(binding, :approval_id)) ||
             {:error, :approval_changed},
         true <-
           snapshot["approval_expires_at"] == iso8601(value(binding, :approval_expires_at)) ||
             {:error, :approval_changed},
         true <-
           to_string(snapshot["reviewed_by_principal_type"]) ==
             to_string(value(binding, :reviewed_by_principal_type)) ||
             {:error, :approval_changed},
         true <-
           to_string(snapshot["reviewed_by_principal_id"]) ==
             to_string(value(binding, :reviewed_by_principal_id)) ||
             {:error, :approval_changed},
         true <-
           snapshot["reviewed_at"] == iso8601(value(binding, :reviewed_at)) ||
             {:error, :approval_changed},
         true <-
           Targeting.snapshot_digest(snapshot["review_metadata"] || %{}) ==
             Targeting.snapshot_digest(value(binding, :review_metadata) || %{}) ||
             {:error, :approval_changed},
         {:ok, expires_at} <- parse_datetime(snapshot["approval_expires_at"]),
         {:ok, issued_at} <- parse_datetime(snapshot["issued_at"]),
         true <- DateTime.after?(expires_at, now) || {:error, :approval_changed},
         true <- not DateTime.after?(issued_at, now) || {:error, :approval_changed},
         :ok <- current_approval_age(phase, issued_at, now) do
      :ok
    else
      false -> {:error, :approval_changed}
      {:error, _reason} = error -> error
    end
  end

  defp current_approval_age(:launch, issued_at, now) do
    age = DateTime.diff(now, issued_at, :second)

    if age in 0..@max_approval_snapshot_age_seconds,
      do: :ok,
      else: {:error, :approval_changed}
  end

  defp current_approval_age(_phase, _issued_at, _now), do: :ok

  defp current_targets(operation, execution, persisted_targets, memberships) do
    membership_by_id = Map.new(memberships, &{to_string(value(&1, :id)), &1})

    with true <-
           map_size(membership_by_id) == length(persisted_targets) ||
             {:error, :target_no_longer_authorized},
         {:ok, targets} <-
           Enum.reduce_while(persisted_targets, {:ok, []}, fn persisted, {:ok, acc} ->
             membership = Map.get(membership_by_id, to_string(value(persisted, :membership_id)))

             case current_target(execution, persisted, membership) do
               {:ok, target} -> {:cont, {:ok, [target | acc]}}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      targets = Enum.sort_by(targets, & &1.awx_host_id)
      target_digest = Targeting.target_digest(targets)
      execution_target_digest = value(value(execution, :metadata) || %{}, :target_digest)
      host_limit = Enum.map_join(targets, ",", & &1.awx_host_name)

      if secure_equal(target_digest, to_string(value(operation, :target_digest))) and
           secure_equal(target_digest, to_string(execution_target_digest)) and
           host_limit == value(execution, :host_limit) do
        {:ok, targets}
      else
        {:error, :target_no_longer_authorized}
      end
    else
      false -> {:error, :target_no_longer_authorized}
      {:error, _reason} = error -> error
    end
  end

  defp current_target(_execution, _persisted, nil), do: {:error, :target_no_longer_authorized}

  defp current_target(execution, persisted, membership) do
    target = %{
      membership_id: to_string(value(membership, :id)),
      controller_id: to_string(value(membership, :controller_id)),
      inventory_id: value(membership, :inventory_id),
      awx_host_id: value(membership, :awx_host_id),
      device_uid: value(membership, :canonical_device_uid),
      awx_host_name: value(membership, :host_name),
      ansible_host: value(membership, :ansible_host),
      membership_generation: value(membership, :source_generation),
      source_fingerprint: value(membership, :source_fingerprint)
    }

    checks = [
      value(membership, :current) == true,
      value(membership, :enabled) == true,
      value(membership, :link_disposition) in [:approved, "approved"],
      target.controller_id == to_string(value(persisted, :controller_id)),
      target.controller_id == to_string(value(execution, :controller_id)),
      target.inventory_id == value(persisted, :inventory_id),
      target.inventory_id == value(execution, :inventory_id),
      target.awx_host_id == value(persisted, :awx_host_id),
      target.device_uid == value(persisted, :canonical_device_uid),
      target.awx_host_name == value(persisted, :host_name),
      target.ansible_host == value(persisted, :ansible_host),
      target.membership_generation == value(persisted, :membership_generation),
      valid_source_fingerprint?(target.source_fingerprint),
      target.source_fingerprint == value(persisted, :source_fingerprint),
      secure_equal(
        Targeting.snapshot_digest(execution_target_snapshot(target)),
        to_string(value(persisted, :snapshot_digest))
      )
    ]

    if Enum.all?(checks), do: {:ok, target}, else: {:error, :target_no_longer_authorized}
  end

  defp normalize_credentials(credentials) when is_list(credentials) and credentials != [] do
    credentials
    |> Enum.reduce_while({:ok, []}, fn credential, {:ok, acc} ->
      normalized = stringify(credential)

      if MapSet.new(Map.keys(normalized)) == MapSet.new(["id", "kind"]) and
           is_integer(normalized["id"]) and normalized["id"] > 0 and
           is_binary(normalized["kind"]) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, normalized} -> Enum.sort_by(normalized, & &1["id"])
      :invalid -> :invalid
    end
  end

  defp normalize_credentials(_credentials), do: :invalid

  defp authorization_version(:human, _principal, owner, profile_versions, permissions) do
    Targeting.snapshot_digest(%{
      "actor_id" => value(owner, :id),
      "actor_status" => to_string(value(owner, :status)),
      "actor_role" => to_string(value(owner, :role)),
      "actor_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_versions" => profile_versions,
      "fresh_permissions" => permissions
    })
  end

  defp authorization_version(:service_principal, principal, owner, profile_versions, permissions) do
    Targeting.snapshot_digest(%{
      "schema" => "serviceradar.service_principal_authorization.v1",
      "service_principal_id" => value(principal, :id),
      "service_principal_owner_id" => value(owner, :id),
      "service_principal_updated_at" => iso8601(value(principal, :updated_at)),
      "service_principal_scopes" => principal |> value(:scopes) |> List.wrap() |> Enum.sort(),
      "owner_status" => to_string(value(owner, :status)),
      "owner_role" => to_string(value(owner, :role)),
      "owner_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_versions" => profile_versions,
      "fresh_permissions" => permissions
    })
  end

  # Operations issued before group profiles existed carry the original
  # singular-profile digest. Adding a group profile deliberately invalidates it.
  defp authorization_version_matches?(
         stored_version,
         type,
         principal,
         owner,
         profile_versions,
         permissions
       ) do
    secure_equal(
      authorization_version(type, principal, owner, profile_versions, permissions),
      stored_version
    ) or
      case profile_versions do
        [{profile_id, profile_updated_at}] ->
          secure_equal(
            legacy_authorization_version(
              type,
              principal,
              owner,
              profile_id,
              profile_updated_at,
              permissions
            ),
            stored_version
          )

        _ ->
          false
      end
  end

  defp legacy_authorization_version(
         :human,
         _principal,
         owner,
         profile_id,
         profile_updated_at,
         permissions
       ) do
    Targeting.snapshot_digest(%{
      "actor_id" => value(owner, :id),
      "actor_status" => to_string(value(owner, :status)),
      "actor_role" => to_string(value(owner, :role)),
      "actor_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_id" => profile_id,
      "profile_updated_at" => profile_updated_at,
      "fresh_permissions" => permissions
    })
  end

  defp legacy_authorization_version(
         :service_principal,
         principal,
         owner,
         profile_id,
         profile_updated_at,
         permissions
       ) do
    Targeting.snapshot_digest(%{
      "schema" => "serviceradar.service_principal_authorization.v1",
      "service_principal_id" => value(principal, :id),
      "service_principal_owner_id" => value(owner, :id),
      "service_principal_updated_at" => iso8601(value(principal, :updated_at)),
      "service_principal_scopes" => principal |> value(:scopes) |> List.wrap() |> Enum.sort(),
      "owner_status" => to_string(value(owner, :status)),
      "owner_role" => to_string(value(owner, :role)),
      "owner_updated_at" => iso8601(value(owner, :updated_at)),
      "profile_id" => profile_id,
      "profile_updated_at" => profile_updated_at,
      "fresh_permissions" => permissions
    })
  end

  defp service_principal_active?(principal, owner_id, operation, now) do
    expires_at = value(principal, :expires_at)
    scopes = principal |> value(:scopes) |> List.wrap()

    value(principal, :enabled) == true and is_nil(value(principal, :revoked_at)) and
      (is_nil(expires_at) or
         (match?(%DateTime{}, expires_at) and DateTime.after?(expires_at, now))) and
      ("write" in scopes or "admin" in scopes) and
      to_string(value(principal, :user_id)) == to_string(owner_id) and
      to_string(owner_id) == to_string(value(operation, :service_principal_owner_id))
  end

  defp exact_nonempty_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, :target_no_longer_authorized}
  end

  defp exact_nonempty_ids(_ids), do: {:error, :target_no_longer_authorized}

  defp authority_phase(attempt) do
    case {value(attempt, :stage), value(attempt, :purpose)} do
      {:launch_job, :accepted_job_proof} -> {:ok, :launch}
      {:fetch_job, :accepted_job_proof} -> {:ok, :accepted_job_proof}
      {:fetch_job, :scope_poll} -> {:ok, :scope_verification}
      {:fetch_host_summaries, :host_scope_proof} -> {:ok, :scope_verification}
      {:fetch_job, :terminal_poll} -> {:ok, :terminal_watchdog}
      {:fetch_host_summaries, :terminal_confirmation} -> {:ok, :terminal_watchdog}
      _ -> {:error, :current_authority_phase_invalid}
    end
  end

  defp operation_state(phase) when phase in [:launch, :accepted_job_proof, :scope_verification],
    do: :dispatching

  defp operation_state(:terminal_watchdog), do: :running

  defp execution_state(phase) when phase in [:launch, :accepted_job_proof], do: :dispatching
  defp execution_state(:scope_verification), do: :launching
  defp execution_state(:terminal_watchdog), do: :running

  defp source(context) when is_list(context), do: Keyword.get(context, :source, AshSource)

  defp source(context) when is_map(context),
    do: Map.get(context, :source) || Map.get(context, "source") || AshSource

  defp source(_context), do: AshSource

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _ -> {:error, :approval_changed}
    end
  end

  defp parse_datetime(_value), do: {:error, :approval_changed}

  defp normalize_principal_type(type) when type in [:human, "human"], do: :human

  defp normalize_principal_type(type) when type in [:service_principal, "service_principal"],
    do: :service_principal

  defp normalize_principal_type(_type), do: :unknown

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp execution_target_snapshot(target) do
    %{
      membership_id: target.membership_id,
      canonical_device_uid: target.device_uid,
      controller_id: target.controller_id,
      inventory_id: target.inventory_id,
      awx_host_id: target.awx_host_id,
      membership_generation: target.membership_generation,
      source_fingerprint: target.source_fingerprint,
      host_name: target.awx_host_name,
      ansible_host: target.ansible_host
    }
  end

  defp valid_source_fingerprint?(value) when is_binary(value),
    do: Regex.match?(@source_fingerprint, value)

  defp valid_source_fingerprint?(_value), do: false

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil
  defp iso8601(value), do: to_string(value)

  defp profile_versions(versions) when is_list(versions) do
    versions
    |> Enum.map(fn version ->
      {to_string(value(version, :id)), iso8601(value(version, :updated_at))}
    end)
    |> Enum.sort()
  end

  defp profile_versions(_versions), do: []

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
