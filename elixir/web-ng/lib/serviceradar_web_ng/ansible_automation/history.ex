defmodule ServiceRadarWebNG.AnsibleAutomation.History do
  @moduledoc """
  Secret-safe read model for hardened Ansible operation history.

  Every database read uses a history-specific Ash action with an allowlisted
  projection. The second projection in this module converts resource structs
  into plain maps shared by the authenticated API and LiveViews. Callback
  references, credential/authority snapshots, approval internals, arbitrary
  metadata, and bearer-capable values stay outside those public projections.
  """

  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.Controller

  @operation_fields [
    :id,
    :action,
    :state,
    :mutating,
    :check_mode,
    :initiator_principal_type,
    :initiator_principal_id,
    :request_source,
    :target_digest,
    :started_at,
    :ended_at,
    :inserted_at,
    :updated_at
  ]

  @execution_fields [
    :id,
    :operation_id,
    :controller_id,
    :inventory_id,
    :job_template_id,
    :project_id,
    :scm_revision,
    :content_sha256,
    :execution_environment_id,
    :check_mode,
    :host_limit,
    :dispatch_id,
    :snapshot_digest,
    :state,
    :awx_job_id,
    :scope_verified_at,
    :started_at,
    :ended_at,
    :inserted_at,
    :updated_at
  ]

  @target_fields [
    :id,
    :execution_id,
    :membership_id,
    :canonical_device_uid,
    :controller_id,
    :inventory_id,
    :awx_host_id,
    :membership_generation,
    :host_name,
    :ansible_host,
    :status,
    :snapshot_digest,
    :inserted_at,
    :updated_at
  ]

  @hold_fields [
    :id,
    :canonical_device_uid,
    :trigger_execution_target_id,
    :transaction_id,
    :generation,
    :trigger_phase,
    :policy_digest,
    :evidence_digest,
    :active,
    :held_at,
    :inserted_at,
    :updated_at
  ]

  @diagnostic_fields [
    {:reason_code, "Reason code", :code},
    {:failure_code, "Failure code", :code},
    {:reason, "Reason", :code},
    {:stage, "Stage", :code},
    {:cancellation_stage, "Cancellation stage", :code},
    {:cancellation_state, "Cancellation state", :code},
    {:ambiguity_reason, "Ambiguity", :code},
    {:awx_status, "AWX status", :code},
    {:mutating?, "Mutating", :boolean},
    {:cancel_required?, "Cancellation required", :boolean},
    {:callback_ready?, "Callback ready", :boolean},
    {:fail_closed, "Fail closed", :boolean},
    {:controller_id, "Controller", :code},
    {:inventory_id, "Inventory", :integer},
    {:expected_host_ids, "Expected AWX hosts", :integer_list},
    {:observed_host_ids, "Observed AWX hosts", :integer_list},
    {:source_digest, "Source digest", :digest},
    {:snapshot_digest, "Snapshot digest", :digest}
  ]

  @type state_filter :: atom() | nil

  @spec list_operations(term(), state_filter()) :: {:ok, [map()]} | {:error, term()}
  def list_operations(scope, state \\ nil) do
    case AutomationOperation.list_history(%{state: state}, scope: scope) do
      {:ok, rows} -> {:ok, Enum.map(rows, &operation_view/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_operation_bundle(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def get_operation_bundle(id, scope) when is_binary(id) do
    with {:ok, operation} when not is_nil(operation) <-
           AutomationOperation.get_history_by_id(id, scope: scope),
         {:ok, execution_rows} <-
           AutomationExecution.list_history_for_operation(operation.id, scope: scope),
         {:ok, executions} <- load_execution_bundles(execution_rows, scope) do
      {:ok, %{operation: operation_view(operation), executions: executions}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_operation_bundle(_id, _scope), do: {:error, :not_found}

  @spec list_device_history(String.t(), term(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_device_history(device_uid, scope, limit \\ 50)

  def list_device_history(device_uid, scope, limit) when is_binary(device_uid) and is_integer(limit) and limit > 0 do
    with {:ok, target_rows} <-
           AutomationExecutionTarget.list_history_for_device(device_uid, scope: scope),
         target_rows = Enum.take(target_rows, limit),
         {:ok, hold_row} <-
           AutomationTargetHold.get_active_history_for_device(device_uid, scope: scope),
         {:ok, execution_rows} <-
           read_batch(AutomationExecution, :list_history_by_ids, ids(target_rows, :execution_id), scope),
         {:ok, operation_rows} <-
           read_batch(
             AutomationOperation,
             :list_history_by_ids,
             ids(execution_rows, :operation_id),
             scope
           ),
         {:ok, controller_rows} <-
           read_batch(Controller, :list_history_by_ids, ids(execution_rows, :controller_id), scope) do
      build_device_history(target_rows, execution_rows, operation_rows, controller_rows, hold_row)
    end
  end

  def list_device_history(_device_uid, _scope, _limit), do: {:ok, []}

  @doc false
  def operation_view(row) when is_map(row) do
    row
    |> project(@operation_fields)
    |> Map.put(:diagnostics, diagnostic_entries(value(row, :diagnostics)))
  end

  @doc false
  def execution_view(row, controller \\ nil) when is_map(row) do
    row
    |> project(@execution_fields)
    |> Map.put(:controller, controller_view(controller, value(row, :controller_id)))
    |> Map.put(:diagnostics, diagnostic_entries(value(row, :diagnostics)))
  end

  @doc false
  def target_view(row, hold \\ nil) when is_map(row) do
    row
    |> project(@target_fields)
    |> Map.put(:diagnostics, diagnostic_entries(value(row, :diagnostics)))
    |> Map.put(:active_hold, hold_view(hold))
  end

  @doc false
  def hold_view(nil), do: nil

  def hold_view(row) when is_map(row) do
    row
    |> project(@hold_fields)
    |> Map.put(:reason, safe_code(value(row, :reason)) || "Details withheld")
  end

  @doc false
  def diagnostic_entries(diagnostics) when is_map(diagnostics) do
    Enum.flat_map(@diagnostic_fields, fn {key, label, kind} ->
      case diagnostic_value(diagnostics, key, kind) do
        nil -> []
        safe_value -> [%{key: key, label: label, value: safe_value}]
      end
    end)
  end

  def diagnostic_entries(_diagnostics), do: []

  defp load_execution_bundles(rows, scope) do
    rows
    |> Enum.reduce_while({:ok, []}, fn execution, {:ok, acc} ->
      with {:ok, controller} <- Controller.get_history_by_id(execution.controller_id, scope: scope),
           {:ok, target_rows} <-
             AutomationExecutionTarget.list_history_for_execution(execution.id, scope: scope),
           {:ok, targets} <- load_targets_with_holds(target_rows, scope) do
        bundle =
          execution
          |> execution_view(controller)
          |> Map.put(:targets, targets)

        {:cont, {:ok, [bundle | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end
  end

  defp load_targets_with_holds(rows, scope) do
    rows
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case AutomationTargetHold.get_active_history_for_device(
             target.canonical_device_uid,
             scope: scope
           ) do
        {:ok, hold} -> {:cont, {:ok, [target_view(target, hold) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp build_device_history(targets, executions, operations, controllers, hold) do
    execution_by_id = index_by_id(executions)
    operation_by_id = index_by_id(operations)
    controller_by_id = index_by_id(controllers)

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      with %{operation_id: operation_id, controller_id: controller_id} = execution <-
             Map.get(execution_by_id, target.execution_id),
           operation when not is_nil(operation) <- Map.get(operation_by_id, operation_id) do
        record = %{
          operation: operation_view(operation),
          execution: execution_view(execution, Map.get(controller_by_id, controller_id)),
          target: target_view(target, hold)
        }

        {:cont, {:ok, [record | acc]}}
      else
        _ -> {:halt, {:error, :incomplete_history_evidence}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp read_batch(_module, _function, [], _scope), do: {:ok, []}

  defp read_batch(module, function, ids, scope) do
    apply(module, function, [ids, [scope: scope]])
  end

  defp ids(rows, field) do
    rows
    |> Enum.map(&value(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp index_by_id(rows), do: Map.new(rows, &{value(&1, :id), &1})

  defp controller_view(nil, controller_id), do: %{id: controller_id, name: nil}

  defp controller_view(controller, controller_id) do
    %{id: value(controller, :id) || controller_id, name: value(controller, :name)}
  end

  defp project(row, fields), do: Map.new(fields, &{&1, value(row, &1)})

  defp diagnostic_value(diagnostics, key, kind) do
    raw = value(diagnostics, key)

    case kind do
      :code -> safe_code(raw)
      :boolean when is_boolean(raw) -> to_string(raw)
      :integer when is_integer(raw) -> Integer.to_string(raw)
      :integer_list when is_list(raw) -> safe_integer_list(raw)
      :digest -> safe_digest(raw)
      _ -> nil
    end
  end

  # Diagnostic codes are intentionally far stricter than arbitrary strings.
  # Spaces, quotes, braces, query strings, and shell-ish punctuation are all
  # rejected, which prevents inspected HTTP errors or bearer material from
  # being rendered as a seemingly harmless "reason".
  defp safe_code(nil), do: nil
  defp safe_code(value) when is_atom(value), do: value |> Atom.to_string() |> safe_code()

  defp safe_code(value) when is_binary(value) do
    if byte_size(value) <= 96 and Regex.match?(~r/\A[a-zA-Z0-9_.:\/-]+\z/, value) and
         not sensitive_text?(value),
       do: value
  end

  defp safe_code(_value), do: nil

  defp safe_digest(value) when is_binary(value) do
    if byte_size(value) <= 160 and Regex.match?(~r/\A(?:sha256:)?[a-fA-F0-9-]+\z/, value),
      do: value
  end

  defp safe_digest(_value), do: nil

  defp safe_integer_list(values) do
    if length(values) <= 100 and Enum.all?(values, &(is_integer(&1) and &1 > 0)) do
      Enum.join(values, ", ")
    end
  end

  defp sensitive_text?(value) do
    value
    |> String.downcase()
    |> then(fn normalized ->
      Enum.any?(
        ["bearer", "token", "secret", "password", "credential", "callback_reference", "authority"],
        &String.contains?(normalized, &1)
      )
    end)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
