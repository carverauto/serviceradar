defmodule ServiceRadar.Plugins.Changes.SerializeEnabledAssignment do
  @moduledoc """
  Serializes writes that leave a plugin assignment enabled, per
  `(partition_id, agent_uid, plugin_id)`, and repeats
  `NoDuplicateEnabledAssignment` under that lock.

  The unique index `plugin_assignments_one_enabled_per_edge_plugin_owner_index`
  refuses two enabled rows of one owner, but not a manual or non-rule policy row
  next to a rule-owned row (see `ServiceRadar.Plugins.AssignmentOwner`). Only the
  validation refuses that pair, and two concurrent writes would both pass it
  because neither sees the other's uncommitted row. This change takes a
  transaction-scoped advisory lock inside the action's transaction before the
  validation reads, so the second writer waits for the first to commit and then
  sees its row.

  The lock is `pg_advisory_xact_lock` and is released at commit or rollback. It
  must stay transaction-scoped: the Repo goes through PgBouncer in transaction
  mode, where a session-level lock could outlive the transaction on a pooled
  server connection.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.Validations.NoDuplicateEnabledAssignment
  alias ServiceRadar.Repo

  # First key of the two-int4 advisory lock form ("PLAS"). The two-int4 form
  # does not share a lock space with the single-bigint form, and no other
  # two-int4 lock uses this class.
  @lock_class 0x504C4153

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &recheck_under_lock/1)
  end

  defp recheck_under_lock(changeset) do
    case enabled_slot(changeset) do
      nil ->
        changeset

      slot ->
        Repo.query!("SELECT pg_advisory_xact_lock($1::int4, hashtext($2))", [
          @lock_class,
          Jason.encode!(slot)
        ])

        case NoDuplicateEnabledAssignment.validate(changeset, [], %{}) do
          :ok -> changeset
          {:error, error} -> Ash.Changeset.add_error(changeset, error)
        end
    end
  end

  defp enabled_slot(changeset) do
    values = Enum.map([:enabled, :partition_id, :agent_uid, :plugin_id], &value(changeset, &1))

    case values do
      [true, partition_id, agent_uid, plugin_id]
      when is_binary(partition_id) and is_binary(agent_uid) and is_binary(plugin_id) ->
        [partition_id, agent_uid, plugin_id]

      _ ->
        nil
    end
  end

  defp value(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> Map.get(changeset.data, attribute)
      value -> value
    end
  end
end
