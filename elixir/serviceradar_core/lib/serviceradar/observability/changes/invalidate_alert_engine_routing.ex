defmodule ServiceRadar.Observability.Changes.InvalidateAlertEngineRouting do
  @moduledoc """
  Drops the stateful alert engine's cached shard routing once a rule change
  commits, so the next batch is routed with the rule set as it now stands
  (`ServiceRadar.Observability.StatefulAlertEngine.ShardRouting`).
  """

  use Ash.Resource.Change

  alias ServiceRadar.Observability.StatefulAlertEngine.ShardRouting

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      ShardRouting.invalidate()
      result
    end)
  end
end
