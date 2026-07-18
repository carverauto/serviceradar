defmodule ServiceRadar.Plugins.PluginTargetPolicyOps do
  @moduledoc """
  Operations for plugin target policies: preview and immediate reconciliation.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PolicyAssignmentPlanner
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SRQLInputResolver

  require Ash.Query

  @policy_recovery_executor SystemActor.system(:plugin_policy_assignment_recovery_executor)

  @spec preview_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_by_id(id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_target_policy_preview))

    with {:ok, %PluginTargetPolicy{} = policy} <- PluginTargetPolicy.get_by_id(id, actor: actor),
         {:ok, resolved_inputs} <- SRQLInputResolver.resolve(policy.input_definitions, opts),
         {:ok, %{assignments: assignments, summary: summary}} <-
           PolicyAssignmentPlanner.plan(policy_to_plan(policy), resolved_inputs, opts) do
      sample_limit = Keyword.get(opts, :sample_limit, 10)
      sample = Enum.take(assignments, sample_limit)
      per_agent_counts = per_agent_counts(assignments)

      {:ok,
       %{
         policy_id: to_string(policy.id),
         summary: summary,
         per_agent_counts: per_agent_counts,
         sample_assignments: sample
       }}
    end
  end

  @spec reconcile_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_by_id(id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_target_policy_reconcile_now))

    with {:ok, %PluginTargetPolicy{} = policy} <- PluginTargetPolicy.get_by_id(id, actor: actor),
         {:ok, result} <- reconcile_policy(policy, opts),
         {:ok, _updated} <- update_policy_summary(policy, result, actor) do
      {:ok, result}
    end
  end

  @spec reconcile_policy(PluginTargetPolicy.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_policy(%PluginTargetPolicy{} = policy, opts \\ []) do
    PolicyAssignmentReconciler.reconcile(
      policy_to_plan(policy),
      policy.input_definitions || [],
      Keyword.put(opts, :chunk_size, policy.chunk_size)
    )
  end

  @doc """
  Reconciles one enabled target policy for exactly one agent's native targets.

  This is intentionally narrower than `reconcile_by_id/2`. Recovery code must
  never use `target_agent_uid`: that option rewrites all resolved rows onto one
  agent for credential-rule materialization. The recovery restriction instead
  filters native rows before planning and restricts stale-row retraction to the
  same agent.
  """
  @spec reconcile_policy_for_agent(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_policy_for_agent(policy_id, agent_uid, opts \\ [])

  def reconcile_policy_for_agent(policy_id, agent_uid, opts)
      when is_binary(policy_id) and is_binary(agent_uid) do
    with actor when not is_nil(actor) <- Keyword.get(opts, :actor),
         true <-
           policy_recovery_executor?(actor) ||
             {:error, :restricted_policy_recovery_requires_recovery_executor},
         {:ok, %PluginTargetPolicy{} = policy} <-
           PluginTargetPolicy.get_by_id(policy_id, actor: actor),
         true <- policy.enabled || {:error, :policy_not_enabled} do
      reconcile_opts =
        opts
        |> Keyword.delete(:target_agent_uid)
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:restrict_agent_uid, agent_uid)
        |> Keyword.put(:agent_scope, [agent_uid])

      reconcile_policy(policy, reconcile_opts)
    else
      nil -> {:error, :explicit_recovery_actor_required}
      {:ok, nil} -> {:error, :policy_not_found}
      false -> {:error, :policy_not_enabled}
      {:error, _reason} = error -> error
    end
  end

  def reconcile_policy_for_agent(_policy_id, _agent_uid, _opts),
    do: {:error, :invalid_policy_recovery_scope}

  defp policy_recovery_executor?(actor) when is_map(actor) do
    actor_value(actor, :id) == @policy_recovery_executor.id and
      actor_value(actor, :role) == @policy_recovery_executor.role
  end

  defp policy_recovery_executor?(_actor), do: false

  defp actor_value(actor, key), do: Map.get(actor, key) || Map.get(actor, Atom.to_string(key))

  defp update_policy_summary(policy, result, actor) do
    attrs = %{
      last_reconciled_at: DateTime.utc_now(),
      last_reconcile_summary: result
    }

    policy
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  defp policy_to_plan(policy) do
    %{
      policy_id: to_string(policy.id),
      policy_version: policy_version(policy),
      plugin_package_id: policy.plugin_package_id,
      params_template: policy.params_template || %{},
      enabled: policy.enabled,
      interval_seconds: policy.interval_seconds,
      timeout_seconds: policy.timeout_seconds
    }
  end

  defp policy_version(policy) do
    ts = policy.updated_at || policy.inserted_at || DateTime.utc_now()
    DateTime.to_unix(ts, :second)
  end

  defp per_agent_counts(assignments) do
    assignments
    |> Enum.reduce(%{}, fn assignment, acc ->
      Map.update(acc, assignment.agent_uid, 1, &(&1 + 1))
    end)
    |> Enum.sort_by(fn {agent_uid, _count} -> agent_uid end)
    |> Enum.map(fn {agent_uid, count} -> %{agent_uid: agent_uid, assignment_count: count} end)
  end
end
