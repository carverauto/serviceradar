defmodule ServiceRadar.Automation.Ansible.CallbackCommandRecovery do
  @moduledoc """
  One bounded recovery scan for durable callback command attempts.

  Side-effect commands are never retransmitted once an AgentCommand row
  exists. Expired create/launch transports move to their read-only
  reconciliation verbs; read-only stages receive a new command UUID.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.CallbackCommandResultCoordinator, as: Coordinator
  alias ServiceRadar.Automation.CallbackGrants.AshStore, as: GrantStore
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Edge.AgentCommand

  require Logger

  @actor SystemActor.system(:automation_callback_command_recovery)
  @terminal_command_states [:completed, :failed, :expired, :canceled, :offline]
  @active_command_states [:queued, :sent, :acknowledged, :running]

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

    cleanup_intents = recover_activation_cleanup(opts)
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
    if DateTime.before?(now, attempt.deadline_at) do
      case fetch_command(attempt.command_id, opts) do
        {:ok, nil} -> recover_without_command(attempt, opts)
        {:ok, %AgentCommand{} = command} -> recover_with_command(attempt, command, now, opts)
        {:error, reason} -> {:error, {:callback_command_fetch_failed, reason}}
      end
    else
      expire_attempt(attempt, now, opts)
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
          process_terminal(command, opts)

        command.status in @active_command_states and command_expired?(command, now) ->
          coordinator(opts).reconcile_transport_ambiguity(attempt, coordinator_opts(opts))

        command.status in @active_command_states ->
          {:ok, :awaiting_terminal_result}

        true ->
          {:error, :callback_command_status_invalid}
      end
    end
  end

  defp process_terminal(command, opts) do
    coordinator(opts).process_persisted(
      command.id,
      command.agent_id,
      command.command_type,
      coordinator_opts(opts)
    )
  end

  defp expire_attempt(attempt, now, opts) do
    with {:ok, lifecycle_opts} <- lifecycle_opts(opts),
         {:ok, _grant} <-
           lifecycle(opts).revoke(
             attempt.grant_id,
             :callback_command_deadline_elapsed,
             lifecycle_opts
           ),
         {:ok, _attempt} <-
           Attempt.mark_deadline_elapsed(
             attempt,
             %{
               now: now,
               processed_at: now,
               outcome_code: "deadline_elapsed_after_revocation",
               last_error_code: "callback_command_deadline_elapsed"
             },
             actor: @actor
           ) do
      {:ok, :deadline_revoked}
    end
  end

  defp recover_activation_cleanup(opts) do
    case list_activation_cleanup_pending(opts) do
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
        state when state in [:deleted, :deleting] -> :ok
        _state -> delete_activated(attempt.grant_id, opts)
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

  defp delete_activated(grant_id, opts) do
    case Keyword.get(opts, :delete_activated) do
      fun when is_function(fun, 1) -> fun.(grant_id)
      _ -> Runtime.delete_activated_credential(grant_id)
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

  defp list_activation_cleanup_pending(opts) do
    case Keyword.get(opts, :activation_cleanup_lister) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Attempt.list_activation_cleanup_pending(actor: @actor)
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
         command.agent_id == attempt.dispatch_agent_id,
       do: :ok,
       else: {:error, :callback_command_recovery_correlation_mismatch}
  end

  defp command_expired?(%AgentCommand{expires_at: %DateTime{} = expires_at}, now),
    do: not DateTime.after?(expires_at, now)

  defp command_expired?(_command, _now), do: false

  defp lifecycle_opts(opts) do
    case Keyword.fetch(opts, :lifecycle_opts) do
      {:ok, lifecycle_opts} when is_list(lifecycle_opts) -> {:ok, lifecycle_opts}
      _ -> Runtime.lifecycle_opts()
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
        :now
      ])

  defp coordinator(opts), do: Keyword.get(opts, :coordinator, Coordinator)
  defp lifecycle(opts), do: Keyword.get(opts, :lifecycle, Lifecycle)

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp error_code(reason),
    do: reason |> inspect(limit: 10, printable_limit: 128) |> String.slice(0, 255)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
