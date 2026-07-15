defmodule ServiceRadar.Inventory.Identity.DuplicateSweepTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.DuplicateSweep

  test "does not use hardware serial ambiguity for unattended merges" do
    types = DuplicateSweep.automatic_merge_identifier_types()

    refute :hardware_serial in types
    assert :agent_id in types
    assert :armis_device_id in types
    assert :integration_id in types
    assert :mac in types
  end
end
