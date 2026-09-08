defmodule ServiceRadar.Automation.Ansible.NorthboundBridge do
  @moduledoc """
  Mirrors linked Ansible playbook run lifecycle updates onto northbound invocations.
  """

  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookRunTarget
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget

  require Logger

  @spec handle_transition({:ok, PlaybookRun.t()} | {:error, term()}, atom(), map(), keyword()) ::
          {:ok, PlaybookRun.t()} | {:error, term()}
  def handle_transition(result, transition, args, opts \\ [])

  def handle_transition({:ok, %PlaybookRun{} = run} = result, transition, args, opts) do
    actor = Keyword.get(opts, :actor)
    _ = sync_transition(run, transition, args, actor)
    result
  end

  def handle_transition(result, _transition, _args, _opts), do: result

  defp sync_transition(%PlaybookRun{} = run, transition, args, actor) do
    with {:ok, invocation_id} <- northbound_invocation_id(run),
         {:ok, invocation} <- get_invocation(invocation_id, actor) do
      case transition do
        :record_launching -> maybe_record_running(invocation, actor)
        :record_running -> maybe_record_running(invocation, actor)
        :record_succeeded -> record_terminal(invocation, run, :succeeded, args, actor)
        :record_partial -> record_terminal(invocation, run, :partial, args, actor)
        :record_failed -> record_terminal(invocation, run, :failed, args, actor)
        :record_unreachable -> record_terminal(invocation, run, :unreachable, args, actor)
        :record_canceled -> record_terminal(invocation, run, :canceled, args, actor)
        _ -> :ok
      end
    else
      {:error, :not_linked} ->
        :ok

      {:error, reason} ->
        Logger.debug("Skipping Ansible northbound lifecycle sync: #{inspect(reason)}")
        :ok
    end
  end

  defp northbound_invocation_id(%PlaybookRun{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "northbound_invocation_id") ||
           Map.get(metadata, :northbound_invocation_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :not_linked}
    end
  end

  defp northbound_invocation_id(_run), do: {:error, :not_linked}

  defp get_invocation(id, actor) do
    case ActionInvocation.get_by_id(id, actor: actor) do
      {:ok, nil} -> {:error, :invocation_not_found}
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invocation_not_found}
    end
  end

  defp maybe_record_running(%ActionInvocation{state: state}, _actor)
       when state in [:running, :succeeded, :failed, :canceled, :suppressed], do: :ok

  defp maybe_record_running(%ActionInvocation{state: :pending} = invocation, actor) do
    with {:ok, dispatched} <- ActionInvocation.record_dispatch(invocation, %{}, actor: actor) do
      _ = ActionInvocation.record_running(dispatched, actor: actor)
    end

    :ok
  end

  defp maybe_record_running(%ActionInvocation{} = invocation, actor) do
    _ = ActionInvocation.record_running(invocation, actor: actor)
    :ok
  end

  defp record_terminal(%ActionInvocation{state: state}, _run, _terminal, _args, _actor)
       when state in [:succeeded, :failed, :canceled, :suppressed], do: :ok

  defp record_terminal(invocation, run, terminal, args, actor) do
    summary = terminal_summary(run, terminal, args)

    result =
      case terminal do
        :succeeded ->
          ActionInvocation.record_succeeded(invocation, success_attrs(run, summary), actor: actor)

        :canceled ->
          ActionInvocation.record_canceled(invocation, %{result_summary: summary}, actor: actor)

        _ ->
          ActionInvocation.record_failed(invocation, failure_attrs(run, terminal, summary),
            actor: actor
          )
      end

    case result do
      {:ok, _updated} ->
        sync_target_results(invocation, run, terminal, actor)

      {:error, reason} ->
        Logger.debug("Failed to update linked northbound invocation: #{inspect(reason)}")
    end

    :ok
  end

  defp success_attrs(run, summary) do
    %{
      result_summary: summary,
      external_correlation_id: awx_job_id(run)
    }
  end

  defp failure_attrs(run, terminal, summary) do
    %{
      result_summary: summary,
      external_correlation_id: awx_job_id(run),
      error_class: "ansible_#{terminal}",
      error_message: Map.get(summary, "summary") || "Ansible playbook #{terminal}"
    }
  end

  defp terminal_summary(run, terminal, args) do
    %{
      "status" => to_string(terminal),
      "summary" => Map.get(args, :summary) || Map.get(args, "summary"),
      "awx_job_id" => run.awx_job_id,
      "playbook_run_id" => run.id,
      "diagnostics" => Map.get(args, :diagnostics) || Map.get(args, "diagnostics") || %{}
    }
  end

  defp sync_target_results(invocation, run, terminal, actor) do
    northbound_targets = list_invocation_targets(invocation.id, actor)
    ansible_targets = list_ansible_targets(run.id, actor)
    now = DateTime.utc_now()

    Enum.each(northbound_targets, fn target ->
      ansible_target =
        Enum.find(ansible_targets, &(to_string(&1.device_uid) == to_string(target.device_uid)))

      _ =
        ActionInvocationTarget.record_result(
          target,
          %{
            status: target_status(ansible_target, terminal),
            completed_at: now,
            result: target_result(ansible_target, run, terminal),
            external_correlation_id: awx_job_id(run)
          },
          actor: actor
        )
    end)
  end

  defp list_invocation_targets(invocation_id, actor) do
    case ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp list_ansible_targets(run_id, actor) do
    case PlaybookRunTarget.list_for_run(run_id, actor: actor) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp target_status(%PlaybookRunTarget{status: :ok}, _terminal), do: :succeeded
  defp target_status(%PlaybookRunTarget{status: :skipped}, _terminal), do: :skipped

  defp target_status(%PlaybookRunTarget{status: status}, _terminal)
       when status in [:failed, :unreachable], do: :failed

  defp target_status(_target, :succeeded), do: :succeeded
  defp target_status(_target, :canceled), do: :skipped
  defp target_status(_target, _terminal), do: :failed

  defp target_result(%PlaybookRunTarget{} = target, run, terminal) do
    %{
      "status" => to_string(target.status),
      "awx_job_id" => run.awx_job_id,
      "playbook_run_id" => run.id,
      "terminal_state" => to_string(terminal),
      "ok_count" => target.ok_count,
      "changed_count" => target.changed_count,
      "failed_count" => target.failed_count,
      "skipped_count" => target.skipped_count,
      "unreachable_count" => target.unreachable_count
    }
  end

  defp target_result(_target, run, terminal) do
    %{
      "status" => to_string(terminal),
      "awx_job_id" => run.awx_job_id,
      "playbook_run_id" => run.id
    }
  end

  defp awx_job_id(%PlaybookRun{awx_job_id: id}) when is_integer(id), do: Integer.to_string(id)
  defp awx_job_id(_run), do: nil
end
