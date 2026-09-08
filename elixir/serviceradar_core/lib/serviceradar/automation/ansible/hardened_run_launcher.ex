defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher do
  @moduledoc """
  Persists a complete hardened launch plan before dispatching AWX.

  Authorization and target canonicalization happen before this module. The
  persistence adapter must atomically create the parent, child, and every
  target; an external command is never dispatched from a partially persisted
  plan.
  """

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator
  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Edge.AgentCommandBus

  @spec launch(map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def launch(plan, controller, opts \\ [])

  def launch(plan, controller, opts) when is_map(plan) do
    now = now(opts)

    with {:ok, edge_principal} <- authenticated_edge_principal(controller, opts),
         :ok <- verify_live_preflight(plan, controller, edge_principal, now, opts) do
      if callback_enabled?(plan) do
        CallbackLaunchOrchestrator.launch(plan, controller, opts)
      else
        launch_without_callback(plan, controller, edge_principal, now, opts)
      end
    end
  end

  def launch(_plan, _controller, _opts), do: {:error, :invalid_launch_plan}

  defp launch_without_callback(plan, controller, _edge_principal, _now, opts) do
    actions = Keyword.get(opts, :actions, AshActions)

    with {:ok, persisted} <- actions.persist_plan(plan, controller),
         :ok <- actions.mark_dispatching(persisted) do
      case actions.dispatch(persisted.attempt) do
        {:ok, outcome} ->
          {:ok, Map.put(persisted, :dispatch_outcome, outcome)}

        {:error, reason} ->
          # The preallocated attempt is already durable. A dispatch error can
          # happen after the AgentCommand was accepted but before the caller
          # observed that fact, so terminalizing here would race recovery and
          # could conceal a live AWX job. Recovery owns the bounded retry or
          # launch reconciliation decision from this point forward.
          {:ok,
           Map.put(
             persisted,
             :dispatch_outcome,
             {:deferred, SafeFailureEvidence.code(reason)}
           )}
      end
    end
  end

  defp callback_enabled?(plan), do: List.wrap(get_in(plan, [:operation, :callback_actions])) != []

  defp verify_live_preflight(plan, controller, edge_principal, now, opts) do
    verification_opts =
      case Keyword.fetch(opts, :preflight_evidence_reader) do
        {:ok, reader} -> [evidence_reader: reader]
        :error -> []
      end

    with {:ok, snapshot} <-
           AwxLaunchPreflightAttestation.verify_persisted(
             value(plan, :operation),
             value(plan, :execution),
             controller,
             now,
             verification_opts
           ) do
      AwxLaunchPreflightAttestation.verify_dispatch_principal(
        snapshot,
        edge_principal.agent_id,
        edge_principal.partition_id
      )
    end
  end

  defp authenticated_edge_principal(controller, opts) do
    resolver =
      Keyword.get(
        opts,
        :edge_principal_resolver,
        &AgentCommandBus.resolve_control_session_evidence/1
      )

    with true <- is_function(resolver, 1),
         {:ok, evidence} when is_map(evidence) <- resolver.(value(controller, :agent_id)),
         agent_id when is_binary(agent_id) <- value(evidence, :agent_id),
         true <- agent_id == value(controller, :agent_id),
         partition_id when is_binary(partition_id) <- value(evidence, :partition_id),
         partition_id = String.trim(partition_id),
         true <- partition_id != "" do
      {:ok, %{agent_id: agent_id, partition_id: partition_id}}
    else
      _ -> {:error, :authenticated_edge_principal_unavailable}
    end
  end

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end

defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions do
  @moduledoc false

  @callback persist_plan(map(), struct()) :: {:ok, map()} | {:error, term()}
  @callback mark_dispatching(map()) :: :ok | {:error, term()}

  @callback dispatch(struct()) :: {:ok, atom()} | {:error, term()}
end

defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher

  @actor SystemActor.system(:ansible_hardened_run_launcher)

  @impl true
  def persist_plan(plan, controller) do
    ServiceRadar.Repo.transaction(fn ->
      with {:ok, operation} <- create_operation(plan.operation),
           {:ok, execution} <- create_execution(plan.execution, operation.id),
           {:ok, targets} <- create_targets(plan.targets, execution.id),
           {:ok, attempt} <- create_launch_attempt(operation, execution, controller) do
        %{operation: operation, execution: execution, targets: targets, attempt: attempt}
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def mark_dispatching(%{operation: operation, execution: execution}) do
    now = DateTime.utc_now()

    fn ->
      with {:ok, _operation} <-
             AutomationOperation.record_state(
               operation,
               %{state: :dispatching, started_at: now},
               actor: @actor
             ),
           {:ok, _execution} <-
             AutomationExecution.record_state(
               execution,
               %{state: :dispatching, started_at: now},
               actor: @actor
             ) do
        :ok
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end
    |> ServiceRadar.Repo.transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def dispatch(attempt), do: SecureExecutionCommandDispatcher.dispatch(attempt)

  defp create_operation(attrs) do
    case AutomationOperation.create_operation(attrs, actor: @actor) do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> {:error, {:operation_create_failed, reason}}
    end
  end

  defp create_execution(attrs, operation_id) do
    attrs = Map.put(attrs, :operation_id, operation_id)

    case AutomationExecution.create_execution(attrs, actor: @actor) do
      {:ok, execution} -> {:ok, execution}
      {:error, reason} -> {:error, {:execution_create_failed, reason}}
    end
  end

  defp create_targets(targets, execution_id) do
    targets
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      attrs = Map.put(attrs, :execution_id, execution_id)

      case AutomationExecutionTarget.create_target(attrs, actor: @actor) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, reason} -> {:halt, {:error, {:target_create_failed, attrs, reason}}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp create_launch_attempt(operation, execution, controller) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    partition_id =
      execution
      |> value(:immutable_launch_snapshot)
      |> value(:dispatch_partition_id)

    with {:ok, agent_id} <- required_dispatch_value(Map.get(controller, :agent_id), :agent),
         {:ok, partition_id} <- required_dispatch_value(partition_id, :partition),
         {:ok, request} <- Contract.launch_request(operation, execution),
         {:ok, attrs} <-
           Contract.build_attempt(
             %{
               operation_id: operation.id,
               execution_id: execution.id,
               controller_id: execution.controller_id,
               dispatch_agent_id: agent_id,
               dispatch_partition_id: partition_id
             },
             execution,
             request,
             stage: :launch_job,
             purpose: :accepted_job_proof,
             command_type: "awx.launch_job",
             deadline_at: DateTime.add(now, 60, :second)
           ),
         {:ok, attempt} <- Attempt.create_planned(attrs, actor: @actor) do
      {:ok, attempt}
    else
      {:error, reason} -> {:error, {:secure_execution_attempt_create_failed, reason}}
    end
  end

  defp required_dispatch_value(value, _kind) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp required_dispatch_value(_value, :agent), do: {:error, :controller_agent_id_missing}

  defp required_dispatch_value(_value, :partition),
    do: {:error, :controller_dispatch_partition_missing}

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
