defmodule ServiceRadarWebNG.Topology.AtlasWatchTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.AtlasWatch

  @moduletag :db_free

  test "unchanged watched content emits nothing, while canonical changes retain unaffected caches" do
    current = %{canonical_revision: 1, levels: %{"global" => hint(2)}}
    assert AtlasWatch.invalidation(current, current) == nil

    assert %{affected_level_ids: [], levels: %{}, reset: false} =
             AtlasWatch.invalidation(current, %{current | canonical_revision: 3})
  end

  test "changed and removed levels are named without invalidating unchanged levels" do
    previous = %{canonical_revision: 1, levels: %{"global" => hint(2), "global:1:0" => hint(3), "global:2:0" => hint(4)}}
    current = %{canonical_revision: 5, levels: %{"global" => hint(6), "global:1:0" => nil, "global:2:0" => hint(4)}}

    assert %{
             previous_canonical_revision: 1,
             canonical_revision: 5,
             affected_level_ids: ["global", "global:1:0"],
             levels: %{"global" => %{revision: 6}, "global:1:0" => nil},
             reset: false
           } = AtlasWatch.invalidation(previous, current)
  end

  test "enriched content changes invalidate even when the canonical generation stays the same" do
    previous = %{canonical_revision: 1, levels: %{"global" => hint(2)}}
    current = %{canonical_revision: 1, levels: %{"global" => %{revision: 3, structure_revision: 2}}}

    assert %{affected_level_ids: ["global"], levels: %{"global" => %{revision: 3, structure_revision: 2}}} =
             AtlasWatch.invalidation(previous, current)
  end

  test "long removed identities produce a small reset marker instead of an oversized hint" do
    ids = for index <- 1..64, do: "members:#{String.duplicate("x", 1_000)}#{index}:0:0"
    previous = %{canonical_revision: 1, levels: Map.new(ids, &{&1, hint(2)})}
    current = %{canonical_revision: 3, levels: Map.new(ids, &{&1, nil})}

    payload = AtlasWatch.invalidation(previous, current)
    assert payload.reset
    assert payload.affected_level_ids == []
    assert payload.levels == %{}
    assert byte_size(Jason.encode!(payload)) < 1_024

    assert %{reset: false, levels: %{"global" => %{revision: 2}}} =
             AtlasWatch.acknowledgement(%{canonical_revision: 1, levels: %{"global" => hint(2)}})

    acknowledgement = AtlasWatch.acknowledgement(current)
    assert acknowledgement == %{canonical_revision: 3, levels: %{}, reset: true}
    assert byte_size(Jason.encode!(acknowledgement)) < 1_024
  end

  test "first successful reconciliation after unavailability marks a reset" do
    assert %{reset: true, previous_canonical_revision: nil} =
             AtlasWatch.invalidation(nil, %{canonical_revision: 1, levels: %{"global" => hint(2)}})
  end

  defp hint(revision), do: %{revision: revision, structure_revision: revision}
end
