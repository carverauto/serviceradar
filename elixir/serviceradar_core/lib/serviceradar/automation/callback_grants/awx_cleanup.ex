defmodule ServiceRadar.Automation.CallbackGrants.AwxCleanup do
  @moduledoc """
  Production cleanup adapter for ephemeral AWX callback credentials.

  Terminal cleanup requires callback authority to already be consumed or
  removed. `delete_activated/2` is the one deliberate exception: the trusted
  result orchestrator may call it only after exact accepted-job and host-scope
  proof activates the grant. It only queues removal of the reusable AWX
  credential record; removal is not confirmed until `CleanupReconciler`
  accepts the asynchronous command result. The already-running execution
  environment can retain its materialized environment.

  Between dispatch and confirmed deletion the AWX credential may remain
  reusable. The callback's exact runtime `JOB_ID` request binding must reject
  copied or relaunched jobs during that window. A delete failure remains
  durable orphan risk, and terminal cleanup retries the exact deletion without
  restoring callback authority.

  AWX host-summary proof does not, by itself, cryptographically attest that the
  execution environment has materialized credential inputs. The orchestrator
  must call the early-delete API only at the post-start scope-proof boundary;
  deployments that need stronger evidence must add a runner-start/materialized
  signal before enabling this optimization.

  Deletion and cancellation are dispatched as ordinary agent
  commands; a successful dispatch means only `queued`. Final cleanup state is
  written by `CleanupReconciler` after the command result returns.

  The delete command uses a cleanup-only AWX binding. It never receives the
  original launch-envelope reference and therefore cannot resolve callback
  bearer material.
  """

  @behaviour ServiceRadar.Automation.CallbackGrants.Cleanup

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller

  @context_schema "serviceradar.automation_callback_cleanup_command/v1"
  @credential_slot "ssh_ca_callback"
  @terminal_modes [:consumed, :revoked, :expired, :job_terminal]

  @impl true
  def cleanup(grant, mode, context) when is_map(grant) and mode in @terminal_modes do
    with {:ok, plan} <- build_plan(grant, mode, context),
         {:ok, controller} <- maybe_load_controller(plan, context) do
      cancel = dispatch_cancel(plan, controller, context)
      credential = dispatch_credential_delete(plan, controller, context)
      result(cancel, credential)
    else
      {:error, statuses} when is_map(statuses) -> {:error, statuses}
      {:error, _reason} -> {:error, failure_statuses(grant, mode)}
    end
  end

  def cleanup(_grant, _mode, _context),
    do:
      {:error,
       %{cleanup_status: :failed, job_cleanup: :cancel_failed, credential_cleanup: :delete_failed}}

  @doc """
  Queues credential deletion after an active grant has exact AWX job and host
  scope proof. It never waits for the asynchronous delete result and never
  cancels the running job.
  """
  @impl true
  def delete_activated(grant, context) when is_map(grant) do
    with {:ok, plan} <- build_plan(grant, :post_activation, context),
         {:ok, controller} <- maybe_load_controller(plan, context) do
      credential = dispatch_credential_delete(plan, controller, context)
      result(:not_required, credential)
    else
      {:error, statuses} when is_map(statuses) -> {:error, statuses}
      {:error, _reason} -> {:error, failure_statuses(grant, :post_activation)}
    end
  end

  def delete_activated(_grant, _context),
    do:
      {:error,
       %{cleanup_status: :failed, job_cleanup: :not_required, credential_cleanup: :delete_failed}}

  defp build_plan(grant, mode, context) do
    scope = value(grant, :awx_scope_snapshot)
    binding = value(grant, :job_binding) || %{}

    with :ok <- terminal_authority_removed(grant, mode),
         {:ok, grant_id} <- uuid(value(grant, :id)),
         {:ok, execution_id} <- uuid(value(grant, :execution_id)),
         {:ok, controller_id} <- uuid(value(scope, :controller_id)),
         {:ok, job_id} <- optional_positive_integer(value(binding, :job_id)),
         :ok <- required_job_identity(mode, job_id),
         :ok <- controller_binding_matches(controller_id, job_id, binding),
         {:ok, dispatch_agent_id} <- nonempty(value(grant, :dispatch_agent_id)),
         {:ok, dispatch_partition_id} <- nonempty(value(grant, :dispatch_partition_id)),
         {:ok, inventory_id} <- positive_integer(value(scope, :inventory_id)),
         {:ok, job_template_id} <- positive_integer(value(scope, :job_template_id)),
         {:ok, credential_type_id} <-
           positive_integer(value(scope, :callback_credential_type_id)),
         {:ok, organization_id} <-
           positive_integer(value(scope, :callback_credential_organization_id)),
         {:ok, injector_sha256} <-
           sha256(value(scope, :callback_credential_injector_digest)),
         {:ok, credential_id} <- optional_positive_integer(value(grant, :ephemeral_credential_id)),
         {:ok, credential_action} <-
           credential_action(
             grant,
             mode,
             credential_id,
             context_value(context, :retry_deleting?, false) == true
           ),
         {:ok, cancel_action} <- cancel_action(grant, mode, job_id) do
      {:ok,
       %{
         grant_id: grant_id,
         execution_id: execution_id,
         controller_id: controller_id,
         dispatch_agent_id: dispatch_agent_id,
         dispatch_partition_id: dispatch_partition_id,
         inventory_id: inventory_id,
         job_template_id: job_template_id,
         credential_type_id: credential_type_id,
         organization_id: organization_id,
         injector_sha256: injector_sha256,
         credential_id: credential_id,
         job_id: job_id,
         mode: mode,
         credential_action: credential_action,
         cancel_action: cancel_action
       }}
    else
      false -> {:error, failure_statuses(grant, mode)}
      {:error, _reason} -> {:error, failure_statuses(grant, mode)}
    end
  end

  defp terminal_authority_removed(grant, :consumed), do: exact_state(grant, :consumed)

  defp terminal_authority_removed(grant, :post_activation) do
    if normalize_atom(value(grant, :state)) == :active and
         value(grant, :binding_verified) == true and
         is_map(value(grant, :job_binding)) do
      :ok
    else
      {:error, :callback_job_not_scope_verified}
    end
  end

  defp terminal_authority_removed(grant, :expired), do: exact_state(grant, :expired)

  defp terminal_authority_removed(grant, mode) when mode in [:revoked, :job_terminal],
    do: exact_state(grant, :revoked)

  defp exact_state(grant, expected) do
    if normalize_atom(value(grant, :state)) == expected,
      do: :ok,
      else: {:error, :callback_authority_not_terminal}
  end

  defp required_job_identity(mode, job_id)
       when mode in [:post_activation, :consumed, :job_terminal] and is_integer(job_id), do: :ok

  defp required_job_identity(mode, nil) when mode in [:revoked, :expired], do: :ok
  defp required_job_identity(_mode, job_id) when is_integer(job_id), do: :ok
  defp required_job_identity(_mode, _job_id), do: {:error, :awx_job_identity_required}

  defp credential_action(grant, mode, credential_id, retry_deleting?) do
    state = normalize_atom(value(grant, :credential_cleanup_state))
    attempted_at = value(grant, :credential_cleanup_attempted_at)

    case {mode, state, credential_id, attempted_at} do
      {mode, state, id, _}
      when mode in @terminal_modes and state in [:pending, :deleting, :deleted, :delete_failed] and
             is_integer(id) ->
        {:ok, :dispatch}

      {:post_activation, :not_created, nil, _} ->
        {:ok, :not_required}

      {:post_activation, :deleted, id, _} when is_integer(id) ->
        {:ok, :not_required}

      {:post_activation, :deleting, id, attempted}
      when retry_deleting? and is_integer(id) and not is_nil(attempted) ->
        {:ok, :dispatch}

      {:post_activation, :deleting, id, attempted}
      when is_integer(id) and not is_nil(attempted) ->
        {:ok, :queued}

      {:post_activation, state, id, _}
      when state in [:pending, :deleting, :delete_failed] and is_integer(id) ->
        {:ok, :dispatch}

      {mode, :not_created, nil, _} when mode in @terminal_modes ->
        {:ok, :not_required}

      _ ->
        {:error, :ambiguous_callback_credential_identity}
    end
  end

  defp cancel_action(_grant, :job_terminal, _job_id), do: {:ok, :confirmed}

  defp cancel_action(_grant, mode, _job_id) when mode in [:consumed, :post_activation],
    do: {:ok, :not_required}

  defp cancel_action(grant, mode, job_id) when mode in [:revoked, :expired] do
    state = normalize_atom(value(grant, :orphan_risk_state))

    case {state, job_id} do
      {:cancel_confirmed, _} ->
        {:ok, :not_required}

      {state, id} when state in [:none, :cancel_requested, :cancel_failed] and is_integer(id) ->
        {:ok, :dispatch}

      {_state, nil} ->
        {:ok, :not_required}

      _ ->
        {:error, :ambiguous_awx_job_identity}
    end
  end

  defp maybe_load_controller(%{credential_action: credential, cancel_action: cancel}, _context)
       when credential != :dispatch and cancel != :dispatch, do: {:ok, nil}

  defp maybe_load_controller(plan, context) do
    loader = context_value(context, :controller_loader, &load_controller/1)

    with true <- is_function(loader, 1),
         {:ok, controller} <- loader.(plan.controller_id),
         true <- same_identifier?(value(controller, :id), plan.controller_id),
         true <- value(controller, :agent_id) == plan.dispatch_agent_id do
      {:ok, controller}
    else
      _ -> {:error, :callback_cleanup_controller_mismatch}
    end
  end

  defp dispatch_cancel(%{cancel_action: :not_required}, _controller, _context), do: :not_required

  defp dispatch_cancel(%{cancel_action: :confirmed}, _controller, _context), do: :cancel_confirmed

  defp dispatch_cancel(%{cancel_action: :dispatch} = plan, controller, context) do
    cancel_job = context_value(context, :cancel_job, &AwxClient.cancel_job/3)
    correlation = correlation_context(plan, :job_cancel)

    with true <- is_function(cancel_job, 3),
         {:ok, command} <-
           cancel_job.(controller, plan.job_id,
             context: correlation,
             required_partition: plan.dispatch_partition_id
           ),
         {:ok, _command_id} <- uuid(value(command, :id)) do
      :cancel_requested
    else
      _ -> :cancel_failed
    end
  end

  defp dispatch_credential_delete(%{credential_action: :not_required}, _controller, _context),
    do: :not_required

  defp dispatch_credential_delete(%{credential_action: :queued}, _controller, _context),
    do: :delete_requested

  defp dispatch_credential_delete(%{credential_action: :dispatch} = plan, controller, context) do
    delete_credential =
      context_value(context, :delete_credential, &AwxClient.delete_callback_credential/4)

    cleanup_binding = %{
      child_execution_id: plan.execution_id,
      inventory_id: plan.inventory_id,
      job_template_id: plan.job_template_id,
      credential_type_id: plan.credential_type_id,
      organization_id: plan.organization_id,
      credential_slot: @credential_slot,
      injector_sha256: plan.injector_sha256
    }

    correlation = correlation_context(plan, :credential_delete)

    with true <- is_function(delete_credential, 4),
         {:ok, command} <-
           delete_credential.(
             controller,
             plan.credential_id,
             cleanup_binding,
             context: correlation,
             required_partition: plan.dispatch_partition_id
           ),
         {:ok, _command_id} <- uuid(value(command, :id)) do
      :delete_requested
    else
      _ -> :delete_failed
    end
  end

  defp correlation_context(plan, kind) do
    %{
      "schema" => @context_schema,
      "grant_id" => plan.grant_id,
      "execution_id" => plan.execution_id,
      "controller_id" => plan.controller_id,
      "dispatch_agent_id" => plan.dispatch_agent_id,
      "dispatch_partition_id" => plan.dispatch_partition_id,
      "awx_job_id" => plan.job_id,
      "credential_id" => plan.credential_id,
      "cleanup_kind" => Atom.to_string(kind),
      "cleanup_mode" => Atom.to_string(plan.mode)
    }
  end

  defp result(cancel, credential) do
    statuses = %{
      cleanup_status: overall_status(cancel, credential),
      job_cleanup: cancel,
      credential_cleanup: credential
    }

    if cancel == :cancel_failed or credential == :delete_failed,
      do: {:error, statuses},
      else: {:ok, statuses}
  end

  defp overall_status(cancel, credential) do
    statuses = [cancel, credential]

    cond do
      Enum.all?(statuses, &(&1 == :not_required)) ->
        :complete

      Enum.any?(statuses, &(&1 in [:cancel_failed, :delete_failed])) and
          Enum.any?(statuses, &(&1 in [:cancel_requested, :delete_requested])) ->
        :partial

      Enum.any?(statuses, &(&1 in [:cancel_failed, :delete_failed])) ->
        :failed

      true ->
        :queued
    end
  end

  defp failure_statuses(grant, mode) do
    credential_state = normalize_atom(value(grant, :credential_cleanup_state))

    %{
      cleanup_status: :failed,
      job_cleanup:
        case mode do
          :job_terminal ->
            if exact_terminal_job_identity?(grant),
              do: :cancel_confirmed,
              else: :cancel_failed

          mode when mode in [:consumed, :post_activation] ->
            :not_required

          _mode ->
            :cancel_failed
        end,
      credential_cleanup:
        if(credential_state in [:not_created, :deleted], do: :not_required, else: :delete_failed)
    }
  end

  defp load_controller(controller_id) do
    case Controller.get_by_id(controller_id,
           actor: SystemActor.system(:automation_callback_awx_cleanup)
         ) do
      {:ok, %Controller{} = controller} -> {:ok, controller}
      {:ok, nil} -> {:error, :controller_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp context_value(context, key, default) when is_list(context),
    do: Keyword.get(context, key, default)

  defp context_value(context, key, default) when is_map(context),
    do: Map.get(context, key, Map.get(context, Atom.to_string(key), default))

  defp context_value(_context, _key, default), do: default

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp uuid(_value), do: {:error, :invalid_uuid}

  defp positive_integer(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(value), do: positive_integer(value)

  defp nonempty(value) when is_binary(value) do
    if value != "" and String.trim(value) == value,
      do: {:ok, value},
      else: {:error, :blank_identifier}
  end

  defp nonempty(_value), do: {:error, :blank_identifier}

  defp sha256(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-f0-9]{64}\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_sha256}
  end

  defp sha256(_value), do: {:error, :invalid_sha256}

  defp same_identifier?(_left, right) when right in [nil, ""], do: true

  defp same_identifier?(left, right), do: to_string(left) == to_string(right)

  defp controller_binding_matches(_controller_id, nil, _binding), do: :ok

  defp controller_binding_matches(controller_id, _job_id, binding) do
    if same_identifier?(controller_id, value(binding, :controller_id)) and
         value(binding, :controller_id) not in [nil, ""],
       do: :ok,
       else: {:error, :controller_binding_mismatch}
  end

  defp exact_terminal_job_identity?(grant) do
    scope = value(grant, :awx_scope_snapshot)
    binding = value(grant, :job_binding)
    controller_id = value(scope, :controller_id)
    bound_controller_id = value(binding, :controller_id)
    job_id = value(binding, :job_id)

    match?({:ok, _normalized}, uuid(controller_id)) and
      same_identifier?(controller_id, bound_controller_id) and
      bound_controller_id not in [nil, ""] and is_integer(job_id) and job_id > 0 and
      job_id <= 2_147_483_647
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    case value do
      "pending" -> :pending
      "active" -> :active
      "consumed" -> :consumed
      "revoked" -> :revoked
      "expired" -> :expired
      "not_created" -> :not_created
      "deleting" -> :deleting
      "deleted" -> :deleted
      "delete_failed" -> :delete_failed
      "none" -> :none
      "cancel_requested" -> :cancel_requested
      "cancel_confirmed" -> :cancel_confirmed
      "cancel_failed" -> :cancel_failed
      _ -> :invalid
    end
  end

  defp normalize_atom(_value), do: :invalid

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
