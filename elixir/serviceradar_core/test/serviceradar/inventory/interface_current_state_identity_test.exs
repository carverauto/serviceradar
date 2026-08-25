defmodule ServiceRadar.Inventory.InterfaceCurrentStateIdentityTest do
  @moduledoc """
  `:unique_interface` is current-state. Including `:timestamp` in the identity
  is the append-only mechanism (GitHub #4021).
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Interface

  test "unique_interface is (device_id, interface_uid), not a poll snapshot" do
    identity =
      Interface
      |> Ash.Resource.Info.identities()
      |> Enum.find(&(&1.name == :unique_interface))

    assert identity.keys == [:device_id, :interface_uid]
    refute :timestamp in identity.keys
  end
end
