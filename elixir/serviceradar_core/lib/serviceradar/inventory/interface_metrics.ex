defmodule ServiceRadar.Inventory.InterfaceMetrics do
  @moduledoc """
  Shared defaults for per-interface SNMP collection.
  """

  @default_selected ["ifInOctets", "ifOutOctets"]

  @spec default_selected() :: [String.t()]
  def default_selected, do: @default_selected
end
