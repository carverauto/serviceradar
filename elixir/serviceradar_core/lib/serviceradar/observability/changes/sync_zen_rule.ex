defmodule ServiceRadar.Observability.Changes.SyncZenRule do
  @moduledoc """
  Syncs Zen rules to the datasvc KV store after create/update/destroy.

  In schema-agnostic mode, the ZenRuleSync GenServer is started as a singleton
  by the application supervisor.
  """

  use Ash.Resource.Change

  require Logger

  alias ServiceRadar.Observability.ZenRuleSync

  @impl true
  def change(changeset, _opts, _context) do
    if Map.get(changeset.context, :skip_zen_sync) do
      changeset
    else
      action_type = changeset.action_type

      Ash.Changeset.after_action(changeset, fn changeset, rule ->
        # Verify ZenRuleSync is running
        ensure_zen_sync_running()
        sync_rule_action(action_type, changeset, rule)
      end)
    end
  end

  defp ensure_zen_sync_running do
    # In schema-agnostic mode, ZenRuleSync is a singleton started by the supervisor
    case ZenRuleSync.whereis() do
      nil ->
        Logger.warning("ZenRuleSync is not running - rule sync may be degraded")

      _pid ->
        :ok
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp key_fields_changed?(old_rule, new_rule) do
    {old_rule.agent_id, old_rule.stream_name, old_rule.subject, old_rule.name} !=
      {new_rule.agent_id, new_rule.stream_name, new_rule.subject, new_rule.name}
  end

  defp sync_rule_action(:destroy, _changeset, rule) do
    maybe_log(ZenRuleSync.delete_rule(rule))
    {:ok, rule}
  end

  defp sync_rule_action(action_type, changeset, rule) do
    if action_type == :update and key_fields_changed?(changeset.data, rule) do
      maybe_log(ZenRuleSync.delete_rule(changeset.data))
    end

    case ZenRuleSync.sync_rule(rule) do
      {:ok, _revision} ->
        {:ok, rule}

      {:error, reason} ->
        Logger.warning("Failed to sync zen rule #{rule.name}: #{inspect(reason)}")
        {:ok, rule}
    end
  end

  defp maybe_log(:ok), do: :ok

  defp maybe_log({:error, reason}) do
    Logger.warning("Failed to delete zen rule from KV: #{inspect(reason)}")
    :ok
  end
end
