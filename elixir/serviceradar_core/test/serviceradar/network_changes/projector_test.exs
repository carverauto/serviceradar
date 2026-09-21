defmodule ServiceRadar.NetworkChanges.ProjectorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ChangeImpact.Snapshot
  alias ServiceRadar.NetworkChanges.Projector

  @change %{
    external_id: "CHG-192-0-2",
    source: "itsm",
    kind: :upgrade,
    status: "scheduled",
    window_start: ~U[2026-01-15 10:00:00.000000Z],
    window_end: ~U[2026-01-15 12:00:00.000000Z],
    selector: %{
      "cidrs" => ["192.0.2.0/24"],
      "device_uids" => ["sr:192.0.2.1"]
    },
    comments: "ticket text must stay off the graph"
  }

  test "graph payload has no comments or diffs" do
    payload = Projector.graph_payload(@change)
    assert payload.id == "CHG-192-0-2"
    assert payload.kind == "upgrade"
    assert payload.affects_prefix_cidrs == ["192.0.2.0/24"]
    assert payload.affects_device_ids == ["sr:192.0.2.1"]
    refute Map.has_key?(payload, :comments)
    refute Map.has_key?(payload, :diff)
  end

  test "snapshot contract is NMS-neutral and has no verdict" do
    snapshot =
      Snapshot.from_parts(
        assets: [%{"id" => "sr:192.0.2.1", "kind" => "device"}],
        prefixes: [%{"cidr" => "192.0.2.0/24"}],
        changes: [Snapshot.change_node(@change)],
        links: [%{"source" => "sr:192.0.2.1", "target" => "sr:198.51.100.1"}]
      )

    assert Map.keys(snapshot) -- ["assets", "links", "prefixes", "changes", "telemetry"] == []
    refute Map.has_key?(snapshot, "postpone")
    refute Map.has_key?(snapshot, "sequence")
    assert hd(snapshot["changes"])["id"] == "CHG-192-0-2"
    refute Map.has_key?(hd(snapshot["changes"]), "comments")
  end
end
