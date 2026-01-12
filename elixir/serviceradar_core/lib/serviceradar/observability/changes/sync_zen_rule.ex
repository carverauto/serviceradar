defmodule ServiceRadar.Observability.Changes.SyncZenRule do
  @moduledoc """
  Syncs Zen rules to the datasvc KV store after create/update/destroy.

  Also ensures the tenant-scoped ZenRuleSync GenServer is running for the tenant.
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
      tenant_schema = changeset.tenant

      Ash.Changeset.after_action(changeset, fn changeset, rule ->
        # Ensure ZenRuleSync is running for this tenant
        ensure_zen_sync_running(rule.tenant_id)

        case action_type do
          :destroy ->
            maybe_log(ZenRuleSync.delete_rule(rule))
            {:ok, rule}

          _ ->
            if action_type == :update and key_fields_changed?(changeset.data, rule) do
              maybe_log(ZenRuleSync.delete_rule(changeset.data))
            end

            case ZenRuleSync.sync_rule(rule, tenant_schema: tenant_schema) do
              {:ok, _revision} ->
                {:ok, rule}

              {:error, reason} ->
                Logger.warning("Failed to sync zen rule #{rule.name}: #{inspect(reason)}")
                {:ok, rule}
            end
        end
      end)
    end
  end

  defp ensure_zen_sync_running(tenant_id) do
    case ZenRuleSync.ensure_started(tenant_id) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to start ZenRuleSync for tenant",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp key_fields_changed?(old_rule, new_rule) do
    {old_rule.agent_id, old_rule.stream_name, old_rule.subject, old_rule.name} !=
      {new_rule.agent_id, new_rule.stream_name, new_rule.subject, new_rule.name}
  end

  defp maybe_log(:ok), do: :ok

  defp maybe_log({:error, reason}) do
    Logger.warning("Failed to delete zen rule from KV: #{inspect(reason)}")
    :ok
  end
end
