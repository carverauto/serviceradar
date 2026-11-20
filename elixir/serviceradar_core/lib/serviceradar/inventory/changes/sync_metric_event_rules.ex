defmodule ServiceRadar.Inventory.Changes.SyncMetricEventRules do
  @moduledoc """
  Ash change that syncs metric-derived EventRules and StatefulAlertRules.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Inventory.MetricRuleSync

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &MetricRuleSync.sync/1)
  end

  @impl true
  # An atomic update never calls change/3, so the hook is registered here too.
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
