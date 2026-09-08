defmodule ServiceRadar.Inventory.VisibilityProfileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.VisibilityProfile

  @tag :visibility
  test "allows DPI, flow attribution, and process snapshot fields" do
    attrs = %{
      name: "Phase 3 Visibility Fields",
      target_query: "in:devices",
      capture_interfaces: ["eth0"],
      dpi: %{"enabled" => true},
      flow_attribution: %{"tcp" => true, "udp" => true, "quic" => false},
      process_snapshot_interval_s: 60
    }

    changeset = Ash.Changeset.for_create(VisibilityProfile, :create, attrs)

    assert changeset.valid?
  end
end
