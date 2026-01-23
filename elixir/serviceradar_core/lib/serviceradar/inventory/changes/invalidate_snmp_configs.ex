defmodule ServiceRadar.Inventory.Changes.InvalidateSnmpConfigs do
  @moduledoc """
  Invalidates SNMP and mapper configs after SNMP credential changes.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AgentConfig.ConfigServer

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      ConfigServer.invalidate(:snmp)
      ConfigServer.invalidate(:mapper)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
