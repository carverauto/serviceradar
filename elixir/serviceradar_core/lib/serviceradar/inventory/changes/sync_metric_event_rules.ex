defmodule ServiceRadar.Inventory.Changes.SyncMetricEventRules do
  @moduledoc """
  Ash change that syncs metric-derived EventRules and StatefulAlertRules.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Inventory.MetricRuleSync

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      MetricRuleSync.sync(record)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
