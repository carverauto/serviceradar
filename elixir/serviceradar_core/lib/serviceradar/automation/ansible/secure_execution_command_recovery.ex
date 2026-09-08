defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandRecovery do
  @moduledoc """
  Bounded recovery scan for durable hardened non-callback command attempts.

  A launch is dispatched only when its preallocated `AgentCommand` row is
  absent. Once that row exists, an expired launch transport moves to bounded
  recent-job reconciliation and is never launched again.
  """

  alias ServiceRadar.Actors.SystemActor

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt,
    as: Attempt

  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Edge.AgentCommand

  require Logger

  @actor SystemActor.system(:secure_execution_command_recovery)
  @terminal_command_states [:completed, :failed, :expired, :canceled, :offline]
  @active_command_states [:queued, :sent, :acknowledged, :running]

  @spec recover_once(keyword()) :: %{attempts: non_neg_integer()}
  def recover_once(opts \\ []) when is_list(opts) do
    now = now(opts)

    case list_recoverable(now, opts) do
      {:ok, rows} ->
        Enum.each(rows, &safe_recover_attempt(&1, now, opts))
        %{attempts: length(rows)}

      {:error, reason} ->
        Logger.warning("secure execution recovery scan failed", reason: error_code(reason))
        %{attempts: 0}
    end
  end

  defp safe_recover_attempt(attempt, now, opts) do
    recover_attempt(attempt, now, opts)
  rescue
    exception ->
      Logger.warning("secure execution recovery item crashed",
        attempt_id: attempt.id,
        exception: exception.__struct__
      )
  catch
    kind, _reason ->
      Logger.warning("secure execution recovery item threw",
        attempt_id: attempt.id,
        failure_kind: kind
      )
  end

  defp recover_attempt(attempt, now, opts) do
    case fetch_command(attempt.command_id, opts) do
      {:ok, nil} ->
        if DateTime.before?(now, attempt.deadline_at),
          do: recover_without_command(attempt, opts),
          else: coordinator(opts).expire_attempt(attempt, coordinator_opts(opts))

      {:ok, %AgentCommand{} = command} ->
        recover_with_command(attempt, command, now, opts)

      {:error, reason} ->
        {:error, {:secure_execution_command_fetch_failed, reason}}
    end
  end

  defp recover_without_command(%Attempt{state: state} = attempt, opts)
       when state in [:planned, :waiting, :dispatching] do
    dispatcher = Keyword.get(opts, :dispatcher, &SecureExecutionCommandDispatcher.dispatch/1)
    dispatcher.(attempt)
  end

  defp recover_without_command(attempt, _opts),
    do: {:error, {:persisted_secure_execution_command_missing, attempt.state}}

  defp recover_with_command(attempt, command, now, opts) do
    with :ok <- exact_command(attempt, command),
         :ok <- reauthorize_inflight_continuation(attempt, command, now, opts) do
      cond do
        command.status in @terminal_command_states ->
          coordinator(opts).process_persisted(
            command.id,
            command.agent_id,
            command.command_type,
            coordinator_opts(opts)
          )

        command.status in @active_command_states and
          attempt.stage == :launch_job and
            (command_expired?(command, now) or not DateTime.before?(now, attempt.deadline_at)) ->
          coordinator(opts).reconcile_transport_ambiguity(attempt, coordinator_opts(opts))

        command.status in @active_command_states and
            not DateTime.before?(now, attempt.deadline_at) ->
          coordinator(opts).expire_attempt(attempt, coordinator_opts(opts))

        command.status in @active_command_states and command_expired?(command, now) ->
          coordinator(opts).reconcile_transport_ambiguity(attempt, coordinator_opts(opts))

        command.status in @active_command_states ->
          {:ok, :awaiting_terminal_result}

        true ->
          {:error, :secure_execution_command_status_invalid}
      end
    end
  end

  defp reauthorize_inflight_continuation(attempt, command, now, opts)
       when command.status in @active_command_states do
    if DateTime.before?(now, attempt.deadline_at) do
      invoke_continuation_authorizer(attempt, opts)
    else
      :ok
    end
  end

  defp reauthorize_inflight_continuation(_attempt, _command, _now, _opts), do: :ok

  defp invoke_continuation_authorizer(attempt, opts) do
    authorizer =
      Keyword.get(
        opts,
        :continuation_authorizer,
        &SecureExecutionCommandDispatcher.reauthorize_continuation/1
      )

    case authorizer.(attempt) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :secure_execution_continuation_reauthorization_unavailable}
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

  defp exact_command(attempt, command) do
    if to_string(command.id) == to_string(attempt.command_id) and
         command.command_type == attempt.command_type and
         command.agent_id == attempt.dispatch_agent_id and
         command.partition_id == attempt.dispatch_partition_id,
       do: :ok,
       else: {:error, :secure_execution_recovery_correlation_mismatch}
  end

  defp command_expired?(%AgentCommand{expires_at: %DateTime{} = expires_at}, now),
    do: not DateTime.after?(expires_at, now)

  defp command_expired?(_command, _now), do: false

  defp coordinator_opts(opts) do
    Keyword.take(opts, [
      :bundle_loader,
      :attempt_bundle_loader,
      :processing_claimer,
      :dispatcher,
      :attempt_store,
      :transaction,
      :rollback,
      :execution_lifecycle_actions,
      :secure_lifecycle_actions,
      :now
    ])
  end

  defp coordinator(opts), do: Keyword.get(opts, :coordinator, Coordinator)

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp error_code(reason), do: SafeFailureEvidence.code(reason)
end
