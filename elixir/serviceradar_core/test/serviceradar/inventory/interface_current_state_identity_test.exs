defmodule ServiceRadar.Inventory.InterfaceCurrentStateIdentityTest do
  @moduledoc """
  `:unique_interface` is current-state. Including `:timestamp` in the identity
  is the append-only mechanism (GitHub #4021).
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Inventory.Interface

  test "unique_interface is (device_id, interface_uid), not a poll snapshot" do
    identity =
      Interface
      |> Info.identities()
      |> Enum.find(&(&1.name == :unique_interface))

    assert identity.keys == [:device_id, :interface_uid]
    refute :timestamp in identity.keys
  end

  test "Ash primary key matches the current-state identity" do
    pk = Info.primary_key(Interface)

    assert pk == [:device_id, :interface_uid]
    refute :timestamp in pk
  end
end
