defmodule ServiceRadar.Inventory.Identity.AliasGuardIdentifiedReadTest do
  @moduledoc """
  Unit coverage (no database) for the identifier-read decision behind the address-merge veto:
  an unreadable device must count as identified so nothing merges on missing evidence.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.AliasGuard

  describe "identified_read_result?/1" do
    test "a device owning an identifier is identified" do
      assert AliasGuard.identified_read_result?({:ok, [%{}]})
    end

    test "a device owning no identifier is not identified" do
      refute AliasGuard.identified_read_result?({:ok, []})
    end

    test "an error result fails closed" do
      assert AliasGuard.identified_read_result?({:error, :forbidden})
      assert AliasGuard.identified_read_result?({:error, %RuntimeError{message: "boom"}})
    end

    test "an unexpected shape fails closed" do
      assert AliasGuard.identified_read_result?(:timeout)
    end
  end
end
