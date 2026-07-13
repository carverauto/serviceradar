defmodule ServiceRadar.Automation.Ansible.ExecutionLifecycle do
  @moduledoc """
  Fail-closed acceptance and target-scope lifecycle for hardened AWX children.

  The bridge supplies normalized, authenticated AWX results. This service
  verifies every immutable launch field before binding `(controller, job)` and
  verifies the post-start host summary before returning callback readiness.
  It never derives target identity from a host name or address.
  """

  alias ServiceRadar.Automation.Ansible.ExecutionLifecycleAshActions

  @type execution :: map() | struct()
  @type target :: map() | struct()

  @doc """
  Verifies and persists an accepted AWX job against its immutable child.

  `authenticated_controller_id` is taken from the trusted command-result
  binding, not from AWX response data. A response may redundantly contain a
  controller ID, but it cannot override that authenticated binding.
  """
  @spec bind_accepted_job(execution(), String.t(), map(), keyword()) ::
          {:ok, execution()} | {:error, term()}
  def bind_accepted_job(execution, authenticated_controller_id, job, opts \\ [])

  def bind_accepted_job(execution, authenticated_controller_id, job, opts)
      when is_map(execution) and is_binary(authenticated_controller_id) and is_map(job) do
    actions = Keyword.get(opts, :actions, ExecutionLifecycleAshActions)

    case accepted_job_snapshot(execution, authenticated_controller_id, job) do
      {:ok, snapshot} ->
        actions.bind_accepted_job(execution, snapshot)

      {:error, reason} ->
        diagnostics =
          rejection_diagnostics(
            :accepted_job_mismatch,
            reason,
            job,
            Keyword.get(opts, :mutating?, false)
          )

        _ = actions.reject_scope(execution, Keyword.get(opts, :targets, []), diagnostics)
        {:error, reason}
    end
  end

  def bind_accepted_job(_execution, _controller_id, _job, _opts),
    do: {:error, :invalid_accepted_job}

  @doc """
  Proves the running job's host-ID set is exactly the persisted target set.

  Callback-owned activation code may run only when this returns
  `{:ok, %{callback_ready?: true, ...}}`. Persistence must complete first.
  """
  @spec verify_host_scope(execution(), [target()], String.t(), pos_integer(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_host_scope(
        execution,
        targets,
        authenticated_controller_id,
        authenticated_job_id,
        summaries,
        opts \\ []
      )

  def verify_host_scope(
        execution,
        targets,
        authenticated_controller_id,
        authenticated_job_id,
        summaries,
        opts
      )
      when is_map(execution) and is_list(targets) and is_binary(authenticated_controller_id) and
             is_integer(authenticated_job_id) and authenticated_job_id > 0 and is_list(summaries) do
    actions = Keyword.get(opts, :actions, ExecutionLifecycleAshActions)

    with :ok <- verify_bound_job(execution, authenticated_controller_id, authenticated_job_id),
         {:ok, normalized_targets} <- normalize_targets(execution, targets),
         {:ok, normalized_summaries} <- normalize_summaries(summaries, authenticated_job_id),
         :ok <- compare_scope(normalized_targets, normalized_summaries),
         evidence = scope_evidence(execution, normalized_targets, normalized_summaries),
         {:ok, updated} <- actions.mark_scope_verified(execution, targets, evidence) do
      {:ok,
       %{
         execution: updated,
         targets: normalized_targets,
         callback_ready?: true,
         scope_evidence: evidence
       }}
    else
      {:error, reason} = error ->
        diagnostics =
          rejection_diagnostics(
            :job_host_scope_mismatch,
            reason,
            summaries,
            Keyword.get(opts, :mutating?, false)
          )

        _ = actions.reject_scope(execution, targets, diagnostics)
        error
    end
  end

  def verify_host_scope(_execution, _targets, _controller_id, _job_id, _summaries, _opts),
    do: {:error, :invalid_job_host_scope}

  @doc false
  @spec accepted_job_snapshot(execution(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def accepted_job_snapshot(execution, authenticated_controller_id, job)
      when is_map(execution) and is_binary(authenticated_controller_id) and is_map(job) do
    expected_credentials =
      execution
      |> value(:credential_snapshot)
      |> value(:credential_ids)
      |> normalize_positive_integer_list()

    actual_credentials = accepted_credential_ids(job)
    expected_created_by_id = execution |> value(:metadata) |> value(:awx_created_by_id)
    actual_created_by_id = job |> value(:launched_by) |> value(:id) |> positive_integer()

    expected_mode = if value(execution, :check_mode), do: "check", else: "run"
    job_id = positive_integer(value(job, :job_id) || value(job, :id))
    markers = value(job, :dispatch_markers)

    checks = [
      {:authenticated_controller_mismatch,
       authenticated_controller_id == value(execution, :controller_id)},
      {:accepted_controller_mismatch,
       optional_equal?(value(job, :controller_id), value(execution, :controller_id))},
      {:accepted_job_id_invalid, not is_nil(job_id)},
      {:accepted_job_rebound,
       is_nil(value(execution, :awx_job_id)) or value(execution, :awx_job_id) == job_id},
      {:accepted_template_mismatch,
       positive_integer(
         value(job, :job_template_id) || value(job, :job_template) || value(job, :template_id)
       ) ==
         value(execution, :job_template_id)},
      {:accepted_inventory_mismatch,
       positive_integer(value(job, :inventory_id) || value(job, :inventory)) ==
         value(execution, :inventory_id)},
      {:accepted_limit_mismatch,
       (value(job, :host_limit) || value(job, :limit)) == value(execution, :host_limit)},
      {:accepted_project_mismatch,
       positive_integer(value(job, :project_id) || value(job, :project)) ==
         value(execution, :project_id)},
      {:accepted_scm_revision_mismatch,
       value(job, :scm_revision) == value(execution, :scm_revision)},
      {:accepted_execution_environment_mismatch,
       positive_integer(
         value(job, :execution_environment_id) || value(job, :execution_environment)
       ) ==
         value(execution, :execution_environment_id)},
      {:accepted_credentials_mismatch,
       expected_credentials != :invalid and expected_credentials == actual_credentials},
      {:accepted_integration_identity_missing,
       is_integer(positive_integer(expected_created_by_id))},
      {:accepted_integration_identity_mismatch,
       positive_integer(expected_created_by_id) == actual_created_by_id},
      {:accepted_mode_mismatch, normalize_job_type(value(job, :job_type)) == expected_mode},
      {:accepted_markers_missing, is_map(markers)},
      {:accepted_dispatch_id_mismatch,
       is_map(markers) and
         value(markers, :serviceradar_dispatch_id) == value(execution, :dispatch_id)},
      {:accepted_snapshot_digest_mismatch,
       is_map(markers) and
         value(markers, :serviceradar_snapshot_digest) == value(execution, :snapshot_digest)}
    ]

    case Enum.find(checks, fn {_reason, valid?} -> not valid? end) do
      {reason, false} ->
        {:error, reason}

      nil ->
        {:ok,
         %{
           "controller_id" => authenticated_controller_id,
           "awx_job_id" => job_id,
           "job_template_id" => value(execution, :job_template_id),
           "inventory_id" => value(execution, :inventory_id),
           "host_limit" => value(execution, :host_limit),
           "project_id" => value(execution, :project_id),
           "scm_revision" => value(execution, :scm_revision),
           "execution_environment_id" => value(execution, :execution_environment_id),
           "credential_ids" => expected_credentials,
           "awx_created_by_id" => positive_integer(expected_created_by_id),
           "job_type" => expected_mode,
           "serviceradar_dispatch_id" => value(execution, :dispatch_id),
           "serviceradar_snapshot_digest" => value(execution, :snapshot_digest)
         }}
    end
  end

  def accepted_job_snapshot(_execution, _controller_id, _job), do: {:error, :invalid_accepted_job}

  defp verify_bound_job(execution, controller_id, job_id) do
    cond do
      value(execution, :controller_id) != controller_id ->
        {:error, :authenticated_controller_mismatch}

      value(execution, :awx_job_id) != job_id ->
        {:error, :authenticated_job_mismatch}

      value(execution, :state) not in [:launching, :scope_verified] ->
        {:error, :execution_not_accepted}

      true ->
        :ok
    end
  end

  defp normalize_targets(execution, targets) do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      normalized = %{
        execution_target_id: value(target, :id),
        execution_id: value(target, :execution_id),
        controller_id: value(target, :controller_id),
        inventory_id: positive_integer(value(target, :inventory_id)),
        awx_host_id: positive_integer(value(target, :awx_host_id)),
        canonical_device_uid: value(target, :canonical_device_uid),
        host_name: value(target, :host_name)
      }

      valid? =
        not blank?(normalized.execution_target_id) and
          normalized.execution_id == value(execution, :id) and
          normalized.controller_id == value(execution, :controller_id) and
          normalized.inventory_id == value(execution, :inventory_id) and
          is_integer(normalized.awx_host_id) and
          not blank?(normalized.canonical_device_uid) and
          not blank?(normalized.host_name)

      if valid? do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt, {:error, :invalid_execution_target_binding}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :execution_targets_required}
      {:ok, normalized} -> reject_duplicates(Enum.reverse(normalized), :target)
      error -> error
    end
  end

  defp normalize_summaries(summaries, authenticated_job_id) do
    summaries
    |> Enum.reduce_while({:ok, []}, fn summary, {:ok, acc} ->
      normalized = %{
        job_id: positive_integer(value(summary, :job_id)),
        awx_host_id: positive_integer(value(summary, :awx_host_id) || value(summary, :host_id)),
        host_name: value(summary, :host_name) || value(summary, :awx_host_name)
      }

      job_bound? = normalized.job_id == authenticated_job_id

      if job_bound? and is_integer(normalized.awx_host_id) and not blank?(normalized.host_name) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt, {:error, :invalid_job_host_summary}}
      end
    end)
    |> case do
      {:ok, normalized} -> reject_duplicates(Enum.reverse(normalized), :summary)
      error -> error
    end
  end

  defp reject_duplicates(values, kind) do
    ids = Enum.map(values, & &1.awx_host_id)
    names = Enum.map(values, & &1.host_name)

    cond do
      length(ids) != MapSet.size(MapSet.new(ids)) ->
        {:error, duplicate_error(kind, :id)}

      length(names) != MapSet.size(MapSet.new(names)) ->
        {:error, duplicate_error(kind, :name)}

      true ->
        {:ok, Enum.sort_by(values, & &1.awx_host_id)}
    end
  end

  defp duplicate_error(:target, :id), do: :duplicate_execution_target_host_id
  defp duplicate_error(:target, :name), do: :duplicate_execution_target_host_name
  defp duplicate_error(:summary, :id), do: :duplicate_job_host_summary_id
  defp duplicate_error(:summary, :name), do: :duplicate_job_host_summary_name

  defp compare_scope(targets, summaries) do
    expected = Enum.map(targets, &Map.take(&1, [:awx_host_id, :host_name]))
    actual = Enum.map(summaries, &Map.take(&1, [:awx_host_id, :host_name]))

    if expected == actual, do: :ok, else: {:error, :job_host_scope_mismatch}
  end

  defp scope_evidence(execution, targets, summaries) do
    %{
      "schema" => "serviceradar.awx_scope_verification.v1",
      "controller_id" => value(execution, :controller_id),
      "awx_job_id" => value(execution, :awx_job_id),
      "execution_id" => value(execution, :id),
      "inventory_id" => value(execution, :inventory_id),
      "expected_host_ids" => Enum.map(targets, & &1.awx_host_id),
      "observed_host_ids" => Enum.map(summaries, & &1.awx_host_id),
      "snapshot_digest" => value(execution, :snapshot_digest)
    }
  end

  defp rejection_diagnostics(stage, reason, source, mutating?) do
    %{
      stage: stage,
      reason: reason,
      mutating?: mutating? == true,
      cancel_required?: true,
      callback_ready?: false,
      source_digest: digest(source)
    }
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_positive_integer_list(values) when is_list(values) do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)) do
      Enum.sort(values)
    else
      :invalid
    end
  end

  defp normalize_positive_integer_list(_), do: :invalid

  defp accepted_credential_ids(job) do
    case value(job, :credential_ids) do
      values when is_list(values) ->
        normalize_positive_integer_list(values)

      _ ->
        job
        |> value(:credentials)
        |> List.wrap()
        |> Enum.map(&(&1 |> value(:id) |> positive_integer()))
        |> normalize_positive_integer_list()
    end
  end

  defp normalize_job_type(type) when type in [:run, "run"], do: "run"
  defp normalize_job_type(type) when type in [:check, "check"], do: "check"
  defp normalize_job_type(_), do: nil

  defp optional_equal?(nil, _expected), do: true
  defp optional_equal?(actual, expected), do: actual == expected

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp blank?(value), do: value in [nil, ""]

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil
end
