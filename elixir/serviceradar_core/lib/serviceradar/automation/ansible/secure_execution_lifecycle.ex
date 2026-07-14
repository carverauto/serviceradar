defmodule ServiceRadar.Automation.Ansible.SecureExecutionLifecycle do
  @moduledoc """
  Durable lifecycle transitions for hardened non-callback AWX executions.

  Accepted-job and host-scope validation stays owned by `ExecutionLifecycle`.
  This module adds the non-callback running/terminal projections and durable
  fail-closed operation state.
  """

  alias ServiceRadar.Automation.Ansible.ExecutionLifecycle
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycleAshActions

  @active_statuses ~w(new pending waiting running)
  @summary_counter_keys ~w(changed dark failures ok processed skipped ignored rescued)

  @spec job_state(map()) :: {:ok, :active | atom()} | {:error, term()}
  def job_state(job) when is_map(job) do
    case normalize_status(value(job, :status)) do
      status when status in @active_statuses -> {:ok, :active}
      "successful" -> {:ok, :succeeded}
      "canceled" -> {:ok, :canceled}
      status when status in ["failed", "error"] -> {:ok, :failed}
      _status -> {:error, :invalid_awx_job_status}
    end
  end

  def job_state(_job), do: {:error, :invalid_awx_job}

  @spec validate_bound_job(map() | struct(), String.t(), map()) :: :ok | {:error, term()}
  def validate_bound_job(execution, authenticated_controller_id, job)
      when is_map(execution) and is_binary(authenticated_controller_id) and is_map(job) do
    with {:ok, observed} <-
           ExecutionLifecycle.accepted_job_snapshot(execution, authenticated_controller_id, job),
         expected = accepted_snapshot(execution),
         true <- observed == expected || {:error, :accepted_job_snapshot_drift} do
      :ok
    else
      false -> {:error, :accepted_job_snapshot_drift}
      {:error, _reason} = error -> error
    end
  end

  def validate_bound_job(_execution, _controller_id, _job), do: {:error, :invalid_awx_job}

  @spec mark_running(map() | struct(), map() | struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_running(operation, execution, opts \\ [])

  def mark_running(operation, execution, opts)
      when is_map(operation) and is_map(execution) and is_list(opts) do
    actions = Keyword.get(opts, :actions, SecureExecutionLifecycleAshActions)

    cond do
      value(operation, :id) != value(execution, :operation_id) ->
        {:error, :secure_execution_operation_mismatch}

      value(execution, :state) == :running and value(operation, :state) == :running ->
        {:ok, %{operation: operation, execution: execution}}

      value(execution, :state) != :scope_verified ->
        {:error, :secure_execution_scope_not_verified}

      value(operation, :state) != :dispatching ->
        {:error, :secure_execution_operation_not_dispatching}

      true ->
        actions.mark_running(operation, execution)
    end
  end

  def mark_running(_operation, _execution, _opts),
    do: {:error, :invalid_secure_execution_lifecycle}

  @spec complete_terminal(
          map() | struct(),
          map() | struct(),
          [map() | struct()],
          String.t(),
          map(),
          [map()],
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def complete_terminal(
        operation,
        execution,
        targets,
        authenticated_controller_id,
        job,
        summaries,
        opts \\ []
      )

  def complete_terminal(
        operation,
        execution,
        targets,
        authenticated_controller_id,
        job,
        summaries,
        opts
      )
      when is_map(operation) and is_map(execution) and is_list(targets) and
             is_binary(authenticated_controller_id) and
             is_map(job) and is_list(summaries) and is_list(opts) do
    actions = Keyword.get(opts, :actions, SecureExecutionLifecycleAshActions)
    job_id = job |> job_id() |> positive_integer()

    with true <-
           value(operation, :id) == value(execution, :operation_id) ||
             {:error, :secure_execution_operation_mismatch},
         true <- value(execution, :state) == :running || {:error, :secure_execution_not_running},
         true <- value(operation, :state) == :running || {:error, :secure_operation_not_running},
         true <- is_integer(job_id) || {:error, :invalid_awx_job_id},
         :ok <- validate_bound_job(execution, authenticated_controller_id, job),
         {:ok, terminal_state} <- terminal_state(job),
         {:ok, :exact} <-
           ExecutionLifecycle.classify_host_scope(
             execution,
             targets,
             authenticated_controller_id,
             job_id,
             summaries
           ),
         {:ok, target_outcomes} <- target_outcomes(targets, summaries, terminal_state),
         evidence = terminal_evidence(execution, job, target_outcomes),
         {:ok, result} <-
           actions.complete_terminal(
             operation,
             execution,
             target_outcomes,
             terminal_state,
             evidence
           ) do
      {:ok, result}
    else
      false -> {:error, :secure_execution_terminal_evidence_mismatch}
      {:retry, :host_scope_incomplete} -> {:error, :terminal_host_summaries_incomplete}
      {:error, _reason} = error -> error
    end
  end

  def complete_terminal(_operation, _execution, _targets, _controller, _job, _summaries, _opts),
    do: {:error, :invalid_secure_execution_terminal_result}

  @spec fail_closed(
          map() | struct(),
          map() | struct(),
          [map() | struct()],
          atom(),
          term(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def fail_closed(operation, execution, targets, state, reason, opts \\ [])

  def fail_closed(operation, execution, targets, state, reason, opts)
      when is_map(operation) and is_map(execution) and is_list(targets) and
             state in [:failed, :dispatch_ambiguous, :cancel_failed] and is_list(opts) do
    actions = Keyword.get(opts, :actions, SecureExecutionLifecycleAshActions)

    with {:ok, evidence_digest} <- SafeFailureEvidence.digest(reason) do
      diagnostics = %{
        "schema" => "serviceradar.secure_execution_failure.v1",
        "reason" => SafeFailureEvidence.code(reason),
        "evidence_digest" => evidence_digest,
        "mutating" => value(operation, :mutating) == true,
        "cancel_required" => Keyword.get(opts, :cancel_required, true),
        "execution_id" => value(execution, :id),
        "snapshot_digest" => value(execution, :snapshot_digest)
      }

      actions.fail_closed(operation, execution, targets, state, diagnostics)
    end
  end

  def fail_closed(_operation, _execution, _targets, _state, _reason, _opts),
    do: {:error, :invalid_secure_execution_failure}

  defp terminal_state(job) do
    case job_state(job) do
      {:ok, :active} -> {:error, :awx_job_not_terminal}
      {:ok, state} when state in [:succeeded, :failed, :canceled] -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp target_outcomes(targets, summaries, terminal_state) do
    summaries_by_id = Map.new(summaries, &{positive_integer(value(&1, :host_id)), &1})

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      host_id = positive_integer(value(target, :awx_host_id))
      summary = summaries_by_id[host_id]

      with true <- is_map(summary) || {:error, :terminal_host_summary_missing},
           {:ok, counters} <- summary_counters(summary) do
        status = target_status(counters, terminal_state)

        diagnostics =
          counters
          |> Map.put("awx_host_id", host_id)
          |> Map.put("host_name", value(summary, :host_name))
          |> Map.put("job_terminal_state", Atom.to_string(terminal_state))

        {:cont, {:ok, [{target, status, diagnostics} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
        false -> {:halt, {:error, :terminal_host_summary_missing}}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.reverse(outcomes)}
      {:error, _reason} = error -> error
    end
  end

  defp summary_counters(summary) do
    @summary_counter_keys
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      value = value(summary, key)

      if is_integer(value) and value >= 0 do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:halt, {:error, :invalid_terminal_host_summary_counter}}
      end
    end)
    |> case do
      {:ok, counters} ->
        failed = value(summary, :failed)

        if is_boolean(failed),
          do: {:ok, Map.put(counters, "failed", failed)},
          else: {:error, :invalid_terminal_host_summary_failed_flag}

      {:error, _reason} = error ->
        error
    end
  end

  defp target_status(_counters, :canceled), do: :canceled

  defp target_status(counters, _terminal_state) do
    cond do
      counters["dark"] > 0 -> :unreachable
      counters["failed"] or counters["failures"] > 0 -> :failed
      counters["processed"] == 0 and counters["skipped"] > 0 -> :skipped
      true -> :ok
    end
  end

  defp terminal_evidence(execution, job, target_outcomes) do
    %{
      "schema" => "serviceradar.awx_terminal_execution.v1",
      "controller_id" => value(execution, :controller_id),
      "execution_id" => value(execution, :id),
      "awx_job_id" => job |> job_id() |> positive_integer(),
      "awx_status" => normalize_status(value(job, :status)),
      "snapshot_digest" => value(execution, :snapshot_digest),
      "targets" =>
        Enum.map(target_outcomes, fn {target, status, diagnostics} ->
          %{
            "execution_target_id" => value(target, :id),
            "awx_host_id" => value(target, :awx_host_id),
            "status" => Atom.to_string(status),
            "changed" => diagnostics["changed"]
          }
        end)
    }
  end

  defp accepted_snapshot(execution) do
    execution
    |> value(:accepted_job_snapshot)
    |> case do
      snapshot when is_map(snapshot) ->
        Map.drop(snapshot, ["scope_verification", :scope_verification])

      _snapshot ->
        %{}
    end
  end

  defp normalize_status(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp job_id(job), do: value(job, :job_id) || value(job, :id) || value(job, :job)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
