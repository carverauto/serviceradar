defmodule ServiceRadar.Inventory.VisibilityProfileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.VisibilityProfile

  @tag :visibility
  test "allows DPI and rejects later-phase network visibility fields" do
    attrs = %{
      name: "Reserved Phase Fields",
      target_query: "in:devices",
      dpi: %{"enabled" => true},
      flow_attribution: %{"enabled" => true},
      process_snapshot_interval_s: 60
    }

    changeset = Ash.Changeset.for_create(VisibilityProfile, :create, attrs)

    refute changeset.valid?

    refute Enum.any?(changeset.errors, &(&1.field == :dpi))

    for field <- [:flow_attribution, :process_snapshot_interval_s] do
      assert Enum.any?(changeset.errors, &(&1.field == field))
    end
  end
end
