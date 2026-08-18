defmodule ServiceRadarWebNG.Plugins.AddonRollouts do
  @moduledoc "Scoped operator access to native add-on fleet rollouts."

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadarWebNG.Plugins.AddonRolloutView

  require Ash.Query

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(100)
    |> Ash.Query.load([:previous_package, :candidate_package, :targets])
    |> read(scope)
    |> present_many(scope)
  rescue
    _ -> []
  end

  def pause(id, opts \\ []), do: transition(:pause, id, opts)
  def resume(id, opts \\ []), do: transition(:resume, id, opts)
  def cancel(id, opts \\ []), do: transition(:cancel, id, opts)
  def rollback(id, opts \\ []), do: transition(:rollback, id, opts)
  def retry(id, opts \\ []), do: transition(:retry, id, opts)

  @spec format_error(term()) :: String.t()
  def format_error(reason) do
    reason
    |> error_text()
    |> scan_known_constraint(reason)
    |> rewrite_known_failures()
    |> truncate_error()
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason) when is_atom(reason), do: known_atom(reason)

  defp error_text(%Ash.Changeset{} = changeset) do
    changeset
    |> Ash.Error.to_error_class()
    |> Exception.message()
  rescue
    _ -> inspect(changeset, limit: 8, printable_limit: 240)
  end

  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text({:error, reason}), do: error_text(reason)
  defp error_text(errors) when is_list(errors), do: Enum.map_join(errors, "; ", &error_text/1)
  defp error_text(reason), do: inspect(reason, limit: 8, printable_limit: 240)

  defp known_atom(:rollout_not_retryable), do: "This rollout can only be retried after it has failed or rolled back."

  defp known_atom(:rollout_not_paused), do: "This rollout is not paused."
  defp known_atom(:rollout_not_active), do: "This rollout is no longer active."
  defp known_atom(:unsupported_operation), do: "That rollout action is not supported."
  defp known_atom(:candidate_not_eligible), do: "The candidate package is no longer eligible."
  defp known_atom(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  # Ash unique-constraint failures often leave the index name on the changeset
  # (or its inspect) rather than in Exception.message/1.
  defp scan_known_constraint(message, reason) do
    cond do
      contains_constraint?(message, "addon_rollout_targets_one_active_target_index") ->
        "addon_rollout_targets_one_active_target_index"

      contains_constraint?(message, "addon_rollouts_one_active_source_index") ->
        "addon_rollouts_one_active_source_index"

      true ->
        scanned = inspect(reason, limit: 20, printable_limit: 2_000)

        cond do
          contains_constraint?(scanned, "addon_rollout_targets_one_active_target_index") ->
            "addon_rollout_targets_one_active_target_index"

          contains_constraint?(scanned, "addon_rollouts_one_active_source_index") ->
            "addon_rollouts_one_active_source_index"

          true ->
            message
        end
    end
  end

  defp contains_constraint?(text, name) when is_binary(text), do: String.contains?(text, name)
  defp contains_constraint?(_text, _name), do: false

  defp rewrite_known_failures(message) when is_binary(message) do
    cond do
      String.contains?(message, "addon_rollout_targets_one_active_target_index") ->
        "An earlier canary for this add-on is still holding one of the agents. Cancel that rollout or retry after it finishes."

      String.contains?(message, "addon_rollouts_one_active_source_index") ->
        "This profile or assignment already has an active rollout."

      true ->
        message
        |> String.split("\n", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()
    end
  end

  defp truncate_error(message) when is_binary(message) do
    if String.length(message) > 280 do
      String.slice(message, 0, 280) <> "…"
    else
      message
    end
  end

  defp transition(action, id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || scope_actor(scope)
    apply(AddonRolloutCoordinator, action, [id, [actor: actor]])
  end

  defp present_many(rollouts, scope) do
    profile_ids = ids_for(rollouts, :profile)
    assignment_ids = ids_for(rollouts, :assignment)
    profiles = load_by_ids(AddonProfile, profile_ids, scope)
    assignments = load_by_ids(AddonAssignment, assignment_ids, scope)

    agent_uids =
      assignments
      |> Map.values()
      |> Enum.map(& &1.agent_uid)
      |> Kernel.++(Enum.flat_map(rollouts, &target_agent_uids/1))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    lookups = %{
      profiles: profiles,
      assignments: assignments,
      agents: load_agents_by_uid(agent_uids, scope)
    }

    rollouts
    |> Enum.map(&AddonRolloutView.present(&1, lookups))
    |> Enum.sort_by(&{&1.sort_rank, sort_time(&1)}, :asc)
  end

  defp ids_for(rollouts, source_type) do
    rollouts
    |> Enum.filter(&(&1.source_type == source_type))
    |> Enum.map(& &1.source_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp target_agent_uids(%{targets: targets}) when is_list(targets) do
    Enum.map(targets, & &1.agent_uid)
  end

  defp target_agent_uids(_rollout), do: []

  defp load_by_ids(_resource, [], _scope), do: %{}

  defp load_by_ids(resource, ids, scope) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> read(scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  defp load_agents_by_uid([], _scope), do: %{}

  defp load_agents_by_uid(uids, scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(uid in ^uids)
    |> read(scope)
    |> Map.new(&{&1.uid, &1})
  rescue
    _ -> %{}
  end

  defp sort_time(%{paused_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond) * -1
  defp sort_time(%{started_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond) * -1
  defp sort_time(%{completed_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond) * -1
  defp sort_time(_rollout), do: 0

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil
end
