defmodule ServiceRadar.Inventory.VisibilityProfileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.VisibilityProfile

  @tag :visibility
  test "rejects reserved later-phase network visibility fields" do
    attrs = %{
      name: "Reserved Phase Fields",
      target_query: "in:devices",
      dpi: %{"enabled" => true},
      flow_attribution: %{"enabled" => true},
      process_snapshot_interval_s: 60
    }

    changeset = Ash.Changeset.for_create(VisibilityProfile, :create, attrs)

    refute changeset.valid?

    for field <- [:dpi, :flow_attribution, :process_snapshot_interval_s] do
      assert Enum.any?(changeset.errors, &(&1.field == field))
    end
  end
end
