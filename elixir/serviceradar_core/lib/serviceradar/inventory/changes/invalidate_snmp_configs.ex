defmodule ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs do
  @moduledoc """
  Invalidates SNMP and mapper configs after SNMP credential changes.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, fn _record ->
      ConfigServer.invalidate(:snmp)
      ConfigServer.invalidate(:mapper)
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
