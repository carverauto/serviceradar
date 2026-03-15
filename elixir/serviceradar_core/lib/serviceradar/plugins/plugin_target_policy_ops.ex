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
