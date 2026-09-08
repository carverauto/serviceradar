defmodule ServiceRadar.Automation.CallbackGrants.Authority do
  @moduledoc false

  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @principal_types [:human, :service_principal, "human", "service_principal"]
  @active_run_states [:authorized, :pending, :running, "authorized", "pending", "running"]
  @active_job_states [:pending, :running, "pending", "running"]

  @spec validate_issue(map(), map(), map()) :: :ok | {:error, term()}
  def validate_issue(grant, current, contract) do
    with :ok <- validate_principal(grant),
         :ok <- validate_current_principal(grant, current),
         :ok <- required_permissions(grant, current, contract),
         :ok <- action_allowed(grant, current),
         :ok <- targets_allowed(grant, current),
         :ok <- issuance_identity_and_limits(grant),
         :ok <- immutable_state_matches(grant, current) do
      active_run(current)
    end
  end

  @spec reauthorize(:activate | :use | :replay, map(), map(), map()) ::
          :ok | {:error, term()}
  def reauthorize(stage, grant, current, contract) when stage in [:activate, :use, :replay] do
    with :ok <- validate_issue(grant, current, contract),
         :ok <- active_job(grant, current) do
      binding_verified(stage, grant)
    end
  end

  @spec target_keys([map()]) :: {:ok, [binary()]} | {:error, term()}
  def target_keys(targets) when is_list(targets) and targets != [] do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      identity = value(target, :target_identity) || target

      normalized = %{
        "controller_id" => value(identity, :controller_id),
        "inventory_id" => value(identity, :inventory_id),
        "awx_host_id" => value(identity, :awx_host_id),
        "canonical_device_uid" =>
          value(identity, :canonical_device_uid) || value(identity, :device_uid)
      }

      if Enum.all?(normalized, fn {_key, value} -> scalar?(value) end) do
        case CanonicalJSON.digest(normalized) do
          {:ok, digest} -> {:cont, {:ok, [digest | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, :invalid_authority_target}}
      end
    end)
    |> case do
      {:ok, keys} ->
        keys = Enum.sort(keys)
        if Enum.uniq(keys) == keys, do: {:ok, keys}, else: {:error, :duplicate_authority_target}

      error ->
        error
    end
  end

  def target_keys(_targets), do: {:error, :authority_targets_required}

  defp validate_principal(grant) do
    type = value(grant, :principal_type)
    id = value(grant, :principal_id)

    cond do
      type not in @principal_types ->
        {:error, :initiating_principal_required}

      blank?(id) ->
        {:error, :initiating_principal_required}

      String.starts_with?(to_string(id), "system:") ->
        {:error, :system_actor_has_no_authority}

      blank?(value(grant, :tenant_id)) ->
        {:error, :tenant_required}

      normalize_type(type) == :service_principal and blank?(value(grant, :principal_owner_id)) ->
        {:error, :service_principal_owner_required}

      true ->
        :ok
    end
  end

  defp validate_current_principal(grant, current) when is_map(current) do
    cond do
      value(current, :enabled) != true ->
        {:error, :principal_disabled}

      normalize_type(value(current, :principal_type)) !=
          normalize_type(value(grant, :principal_type)) ->
        {:error, :principal_changed}

      to_string(value(current, :principal_id)) != to_string(value(grant, :principal_id)) ->
        {:error, :principal_changed}

      to_string(value(current, :tenant_id)) != to_string(value(grant, :tenant_id)) ->
        {:error, :tenant_changed}

      normalize_type(value(current, :principal_type)) == :system ->
        {:error, :system_actor_has_no_authority}

      normalize_type(value(grant, :principal_type)) == :service_principal and
          to_string(value(current, :principal_owner_id) || value(current, :owner_id)) !=
            to_string(value(grant, :principal_owner_id)) ->
        {:error, :service_principal_owner_changed}

      true ->
        :ok
    end
  end

  defp validate_current_principal(_grant, _current), do: {:error, :current_authority_required}

  defp required_permissions(grant, current, contract) do
    ceiling = value(grant, :issuance_ceiling) || %{}
    ceiling_permissions = MapSet.new(List.wrap(value(ceiling, :permissions)))
    current_permissions = MapSet.new(List.wrap(value(current, :permissions)))
    required = MapSet.new(ActionContract.required_permissions(contract))

    cond do
      not MapSet.subset?(required, ceiling_permissions) ->
        {:error, :issuance_permission_ceiling_exceeded}

      not MapSet.subset?(required, current_permissions) ->
        {:error, :current_permission_denied}

      true ->
        :ok
    end
  end

  defp action_allowed(grant, current) do
    ceiling = value(grant, :issuance_ceiling) || %{}
    action = value(grant, :action)

    cond do
      action not in List.wrap(value(ceiling, :actions)) ->
        {:error, :action_outside_issuance_ceiling}

      action not in List.wrap(value(current, :actions)) ->
        {:error, :action_no_longer_authorized}

      true ->
        :ok
    end
  end

  defp targets_allowed(grant, current) do
    requested = MapSet.new(List.wrap(value(grant, :target_keys)))
    ceiling = value(grant, :issuance_ceiling) || %{}
    ceiling_targets = MapSet.new(List.wrap(value(ceiling, :target_keys)))
    current_targets = MapSet.new(List.wrap(value(current, :target_keys)))

    cond do
      MapSet.size(requested) == 0 -> {:error, :grant_targets_required}
      not MapSet.subset?(requested, ceiling_targets) -> {:error, :target_outside_issuance_ceiling}
      not MapSet.subset?(requested, current_targets) -> {:error, :target_no_longer_authorized}
      true -> :ok
    end
  end

  defp issuance_identity_and_limits(grant) do
    ceiling = value(grant, :issuance_ceiling) || %{}
    issued_at = value(grant, :issued_at)
    expires_at = value(grant, :expires_at)
    ceiling_ttl = value(ceiling, :max_ttl_seconds)
    ceiling_budget = value(ceiling, :success_budget)

    cond do
      to_string(value(ceiling, :tenant_id)) != to_string(value(grant, :tenant_id)) ->
        {:error, :tenant_outside_issuance_ceiling}

      normalize_type(value(ceiling, :principal_type)) !=
          normalize_type(value(grant, :principal_type)) ->
        {:error, :principal_outside_issuance_ceiling}

      to_string(value(ceiling, :principal_id)) != to_string(value(grant, :principal_id)) ->
        {:error, :principal_outside_issuance_ceiling}

      not is_integer(ceiling_ttl) or ceiling_ttl <= 0 or
        not match?(%DateTime{}, issued_at) or not match?(%DateTime{}, expires_at) or
          DateTime.diff(expires_at, issued_at, :second) > ceiling_ttl ->
        {:error, :ttl_outside_issuance_ceiling}

      not is_integer(ceiling_budget) or value(grant, :budget_total) > ceiling_budget ->
        {:error, :budget_outside_issuance_ceiling}

      true ->
        :ok
    end
  end

  defp immutable_state_matches(grant, current) do
    checks = [
      {:approval_digest, :approval_changed},
      {:policy_digest, :target_policy_changed},
      {:scope_digest, :awx_binding_changed}
    ]

    Enum.reduce_while(checks, :ok, fn {field, reason}, :ok ->
      if secure_scalar_equal?(value(grant, field), value(current, field)),
        do: {:cont, :ok},
        else: {:halt, {:error, reason}}
    end)
  end

  defp active_run(current) do
    if value(current, :run_state) in @active_run_states,
      do: :ok,
      else: {:error, :run_not_active}
  end

  defp active_job(grant, current) do
    binding = value(grant, :job_binding) || %{}
    current_job_id = value(current, :job_id)

    cond do
      value(current, :job_state) not in @active_job_states ->
        {:error, :job_not_active}

      blank?(value(binding, :job_id)) ->
        {:error, :job_binding_required}

      to_string(current_job_id) != to_string(value(binding, :job_id)) ->
        {:error, :job_binding_changed}

      true ->
        :ok
    end
  end

  defp binding_verified(:activate, _grant), do: :ok

  defp binding_verified(_stage, grant) do
    if value(grant, :binding_verified) == true,
      do: :ok,
      else: {:error, :awx_binding_not_verified}
  end

  defp secure_scalar_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_scalar_equal?(left, right), do: left == right and not is_nil(left)

  defp normalize_type(value) when is_binary(value) do
    case value do
      "human" -> :human
      "service_principal" -> :service_principal
      "system" -> :system
      _ -> :unknown
    end
  end

  defp normalize_type(value) when is_atom(value), do: value
  defp normalize_type(_value), do: :unknown

  defp scalar?(value), do: (is_binary(value) and value != "") or is_integer(value)
  defp blank?(value), do: is_nil(value) or value == ""

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
