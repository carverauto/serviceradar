defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher do
  @moduledoc """
  Persists a complete hardened launch plan before dispatching AWX.

  Authorization and target canonicalization happen before this module. The
  persistence adapter must atomically create the parent, child, and every
  target; an external command is never dispatched from a partially persisted
  plan.
  """

  alias ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions

  @spec launch(map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def launch(plan, controller, opts \\ [])

  def launch(plan, controller, opts) when is_map(plan) do
    actions = Keyword.get(opts, :actions, AshActions)

    with {:ok, persisted} <- actions.persist_plan(plan),
         :ok <- actions.mark_dispatching(persisted) do
      case actions.dispatch(
             controller,
             plan.execution.job_template_id,
             plan.launch_opts,
             dispatch_context(plan, persisted, opts)
           ) do
        {:ok, command} ->
          {:ok, Map.put(persisted, :command, command)}

        {:error, reason} ->
          _ = actions.mark_dispatch_failed(persisted, reason)
          {:error, {:dispatch_failed, reason}}
      end
    end
  end

  def launch(_plan, _controller, _opts), do: {:error, :invalid_launch_plan}

  defp dispatch_context(plan, persisted, opts) do
    plan.command_context
    |> Map.merge(%{
      "operation_id" => persisted.operation.id,
      "execution_id" => persisted.execution.id
    })
    |> maybe_put("northbound_invocation_id", Keyword.get(opts, :northbound_invocation_id))
    |> maybe_put("schedule_id", Keyword.get(opts, :schedule_id))
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions do
  @moduledoc false

  @callback persist_plan(map()) :: {:ok, map()} | {:error, term()}
  @callback mark_dispatching(map()) :: :ok | {:error, term()}

  @callback dispatch(struct(), pos_integer(), map(), map()) ::
              {:ok, struct()} | {:error, term()}

  @callback mark_dispatch_failed(map(), term()) :: :ok | {:error, term()}
end

defmodule ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.HardenedRunLauncher.Actions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AwxClient

  @actor SystemActor.system(:ansible_hardened_run_launcher)

  @impl true
  def persist_plan(plan) do
    ServiceRadar.Repo.transaction(fn ->
      with {:ok, operation} <- create_operation(plan.operation),
           {:ok, execution} <- create_execution(plan.execution, operation.id),
           {:ok, targets} <- create_targets(plan.targets, execution.id) do
        %{operation: operation, execution: execution, targets: targets}
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def mark_dispatching(%{operation: operation, execution: execution}) do
    now = DateTime.utc_now()

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
    end
  end

  @impl true
  def dispatch(controller, template_id, launch_opts, context) do
    AwxClient.launch_job(
      controller,
      template_id,
      launch_opts,
      source: :automation,
      context: context
    )
  end

  @impl true
  def mark_dispatch_failed(%{operation: operation, execution: execution}, reason) do
    now = DateTime.utc_now()
    diagnostics = %{"reason" => inspect(reason)}

    with {:ok, _execution} <-
           AutomationExecution.record_state(
             execution,
             %{state: :failed, ended_at: now, diagnostics: diagnostics},
             actor: @actor
           ),
         {:ok, _operation} <-
           AutomationOperation.record_state(
             operation,
             %{state: :failed, ended_at: now, diagnostics: diagnostics},
             actor: @actor
           ) do
      :ok
    end
  end

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
end
