defmodule ServiceRadar.Automation.Ansible.CallbackCommandRecovery do
  @moduledoc """
  One bounded recovery scan for durable callback command attempts.

  Side-effect commands are never retransmitted once an AgentCommand row
  exists. Expired create/launch transports move to their read-only
  reconciliation verbs; read-only stages receive a new command UUID.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.CallbackCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Automation.CallbackGrants.AshStore, as: GrantStore
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Edge.AgentCommand

  require Logger

  @actor SystemActor.system(:automation_callback_command_recovery)
  @terminal_command_states [:completed, :failed, :expired, :canceled, :offline]
  @active_command_states [:queued, :sent, :acknowledged, :running]
  @activation_cleanup_retry_seconds 120

  @spec recover_once(keyword()) :: %{
          attempts: non_neg_integer(),
          cleanup_intents: non_neg_integer()
        }
  def recover_once(opts \\ []) when is_list(opts) do
    now = now(opts)

    attempts =
      case list_recoverable(now, opts) do
        {:ok, rows} ->
          Enum.each(rows, &safe_recover_attempt(&1, now, opts))
          length(rows)

        {:error, reason} ->
          Logger.warning("callback attempt recovery scan failed", reason: error_code(reason))
          0
      end

    cleanup_intents = recover_activation_cleanup(now, opts)
    %{attempts: attempts, cleanup_intents: cleanup_intents}
  end

  defp safe_recover_attempt(attempt, now, opts) do
    recover_attempt(attempt, now, opts)
  rescue
    exception ->
      Logger.warning("callback attempt recovery item crashed",
        attempt_id: attempt.id,
        exception: exception.__struct__
      )
  catch
    kind, _reason ->
      Logger.warning("callback attempt recovery item threw",
        attempt_id: attempt.id,
        failure_kind: kind
      )
  end

  defp recover_attempt(attempt, now, opts) do
    # Read the durable command before applying the deadline. A terminal result
    # may contain the only trustworthy selector for an externally created AWX
    # object; expiring first would discard it and strand that object forever.
    case fetch_command(attempt.command_id, opts) do
      {:ok, nil} ->
        if DateTime.before?(now, attempt.deadline_at),
          do: recover_without_command(attempt, opts),
          else: expire_attempt(attempt, now, opts)

      {:ok, %AgentCommand{} = command} ->
        recover_with_command(attempt, command, now, opts)

      {:error, reason} ->
        {:error, {:callback_command_fetch_failed, reason}}
    end
  end

  defp recover_without_command(%Attempt{state: state} = attempt, opts)
       when state in [:planned, :waiting, :dispatching] do
    dispatcher = Keyword.get(opts, :dispatcher, &CallbackCommandDispatcher.dispatch/1)
    dispatcher.(attempt)
  end

  defp recover_without_command(attempt, _opts),
    do: {:error, {:persisted_callback_command_missing, attempt.state}}

  defp recover_with_command(attempt, command, now, opts) do
    with :ok <- exact_command(attempt, command) do
      cond do
        command.status in @terminal_command_states ->
          process_terminal(
            command,
            opts,
            cleanup_only?:
              attempt.cleanup_only == true or not DateTime.before?(now, attempt.deadline_at)
          )

        not DateTime.before?(now, attempt.deadline_at) ->
          expire_attempt(attempt, now, opts)

        command.status in @active_command_states and command_expired?(command, now) ->
          with :ok <- reauthorize_inflight_continuation(attempt, command, opts) do
            coordinator(opts).reconcile_transport_ambiguity(attempt, coordinator_opts(opts))
          end

        command.status in @active_command_states ->
          with :ok <- reauthorize_inflight_continuation(attempt, command, opts) do
            {:ok, :awaiting_terminal_result}
          end

        true ->
          {:error, :callback_command_status_invalid}
      end
    end
  end

  defp reauthorize_inflight_continuation(attempt, command, opts)
       when command.status in @active_command_states do
    authorizer =
      Keyword.get(
        opts,
        :continuation_authorizer,
        &CallbackCommandDispatcher.reauthorize_continuation/1
      )

    case authorizer.(attempt) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :callback_continuation_reauthorization_unavailable}
    end
  end

  defp reauthorize_inflight_continuation(_attempt, _command, _opts), do: :ok

  defp process_terminal(command, opts, process_opts) do
    coordinator_opts =
      opts
      |> coordinator_opts()
      |> Keyword.put(:cleanup_only, Keyword.get(process_opts, :cleanup_only?, false))

    coordinator(opts).process_persisted(
      command.id,
      command.agent_id,
      command.command_type,
      coordinator_opts
    )
  end

  defp expire_attempt(attempt, now, opts) do
    with {:ok, lifecycle_opts} <- lifecycle_opts(opts),
         revoke_result =
           lifecycle(opts).revoke(
             attempt.grant_id,
             :callback_command_deadline_elapsed,
             lifecycle_opts
           ),
         :ok <- authority_removed(revoke_result),
         :ok <- fail_postactivation_execution(attempt, opts),
         {:ok, _attempt} <-
           mark_deadline_elapsed(
             attempt,
             %{
               now: now,
               processed_at: now,
               outcome_code: "deadline_elapsed_after_revocation",
               last_error_code: "callback_command_deadline_elapsed"
             },
             opts
           ) do
      {:ok, :deadline_revoked}
    end
  end

  defp fail_postactivation_execution(%Attempt{purpose: purpose} = attempt, opts)
       when purpose in [:terminal_poll, :terminal_confirmation] do
    handler =
      Keyword.get(opts, :postactivation_failure_handler, fn attempt, reason ->
        fail_postactivation_persisted(attempt, reason, opts)
      end)

    case handler.(attempt, :callback_command_deadline_elapsed) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :callback_postactivation_failure_unconfirmed}
    end
  end

  defp fail_postactivation_execution(_attempt, _opts), do: :ok

  defp fail_postactivation_persisted(attempt, reason, opts) do
    with {:ok, %AutomationOperation{} = operation} <-
           required(AutomationOperation.get_by_id(attempt.operation_id, actor: @actor)),
         {:ok, %AutomationExecution{} = execution} <-
           required(AutomationExecution.get_by_id(attempt.execution_id, actor: @actor)),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(attempt.execution_id, actor: @actor),
         true <- targets != [] || {:error, :callback_execution_targets_missing},
         {:ok, _failed} <-
           SecureExecutionLifecycle.fail_closed(
             operation,
             execution,
             targets,
             :cancel_failed,
             reason,
             Keyword.put(secure_lifecycle_opts(opts), :cancel_required, true)
           ) do
      :ok
    else
      false -> {:error, :callback_execution_targets_missing}
      {:error, _reason} = error -> error
    end
  end

  defp mark_deadline_elapsed(attempt, attrs, opts) do
    case Keyword.get(opts, :deadline_marker) do
      fun when is_function(fun, 2) -> fun.(attempt, attrs)
      _ -> Attempt.mark_deadline_elapsed(attempt, attrs, actor: @actor)
    end
  end

  defp authority_removed({:ok, _grant}), do: :ok

  defp authority_removed({:error, {:grant_already_terminal, state}})
       when state in [:revoked, :expired], do: :ok

  defp authority_removed({:error, _reason} = error), do: error

  defp recover_activation_cleanup(now, opts) do
    case list_activation_cleanup_pending(now, opts) do
      {:ok, attempts} ->
        Enum.each(attempts, &safe_recover_activation_cleanup(&1, opts))
        length(attempts)

      {:error, reason} ->
        Logger.warning("callback activation cleanup scan failed", reason: error_code(reason))
        0
    end
  end

  defp safe_recover_activation_cleanup(attempt, opts) do
    with {:ok, grant} <- fetch_grant(attempt.grant_id, opts) do
      case value(grant, :credential_cleanup_state) do
        :deleted -> :ok
        :deleting -> delete_activated(attempt.grant_id, true, opts)
        _state -> delete_activated(attempt.grant_id, false, opts)
      end
    end
  rescue
    exception ->
      Logger.warning("callback activation cleanup recovery crashed",
        attempt_id: attempt.id,
        exception: exception.__struct__
      )
  catch
    kind, _reason ->
      Logger.warning("callback activation cleanup recovery threw",
        attempt_id: attempt.id,
        failure_kind: kind
      )
  end

  defp delete_activated(grant_id, retry_deleting?, opts) do
    case Keyword.get(opts, :delete_activated) do
      fun when is_function(fun, 2) -> fun.(grant_id, retry_deleting?)
      fun when is_function(fun, 1) -> fun.(grant_id)
      _ -> Runtime.delete_activated_credential(grant_id, retry_deleting?: retry_deleting?)
    end
  end

  defp fetch_command(command_id, opts) do
    fetcher = Keyword.get(opts, :command_fetcher, &fetch_persisted_command/1)
    fetcher.(command_id)
  end

  defp fetch_persisted_command(command_id), do: AgentCommand.get_by_id(command_id, actor: @actor)

  defp list_recoverable(now, opts) do
    case Keyword.get(opts, :attempt_lister) do
      fun when is_function(fun, 1) -> fun.(now)
      _ -> Attempt.list_recoverable(now, actor: @actor)
    end
  end

  defp list_activation_cleanup_pending(now, opts) do
    retry_before = DateTime.add(now, -@activation_cleanup_retry_seconds, :second)

    case Keyword.get(opts, :activation_cleanup_lister) do
      fun when is_function(fun, 1) -> fun.(retry_before)
      fun when is_function(fun, 0) -> fun.()
      _ -> Attempt.list_activation_cleanup_pending(retry_before, actor: @actor)
    end
  end

  defp fetch_grant(grant_id, opts) do
    case Keyword.get(opts, :grant_fetcher) do
      fun when is_function(fun, 1) -> fun.(grant_id)
      _ -> GrantStore.fetch(grant_id, nil)
    end
  end

  defp exact_command(attempt, command) do
    if to_string(command.id) == to_string(attempt.command_id) and
         command.command_type == attempt.command_type and
         command.agent_id == attempt.dispatch_agent_id and
         command.partition_id == attempt.dispatch_partition_id,
       do: :ok,
       else: {:error, :callback_command_recovery_correlation_mismatch}
  end

  defp command_expired?(%AgentCommand{expires_at: %DateTime{} = expires_at}, now),
    do: not DateTime.after?(expires_at, now)

  defp command_expired?(_command, _now), do: false

  defp lifecycle_opts(opts) do
    case Keyword.fetch(opts, :lifecycle_opts) do
      {:ok, lifecycle_opts} when is_list(lifecycle_opts) -> {:ok, lifecycle_opts}
      _ -> Runtime.internal_opts()
    end
  end

  defp coordinator_opts(opts),
    do:
      Keyword.take(opts, [
        :bundle_loader,
        :processing_claimer,
        :dispatcher,
        :lifecycle,
        :lifecycle_opts,
        :delete_activated,
        :execution_lifecycle_actions,
        :secure_lifecycle_actions,
        :controller_provenance,
        :controller_provenance_opts,
        :controller_credential_provenance,
        :controller_credential_lookup,
        :now
      ])

  defp coordinator(opts), do: Keyword.get(opts, :coordinator, Coordinator)
  defp lifecycle(opts), do: Keyword.get(opts, :lifecycle, Lifecycle)

  defp secure_lifecycle_opts(opts) do
    case Keyword.get(opts, :secure_lifecycle_actions) do
      nil -> []
      actions -> [actions: actions]
    end
  end

  defp required({:ok, nil}), do: {:error, :callback_command_resource_not_found}
  defp required({:ok, value}), do: {:ok, value}
  defp required({:error, reason}), do: {:error, reason}

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp error_code(reason), do: SafeFailureEvidence.code(reason)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
