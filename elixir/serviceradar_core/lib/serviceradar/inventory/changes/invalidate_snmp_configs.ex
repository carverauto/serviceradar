defmodule ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs do
  @moduledoc """
  Invalidates SNMP and mapper configs after SNMP credential changes.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, fn record ->
      ConfigServer.invalidate(:snmp, {:device, record.device_id})
      ConfigServer.invalidate(:mapper)
    end)
  end

  @impl true
  # An atomic update never calls change/3, so the hook is registered here too.
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
