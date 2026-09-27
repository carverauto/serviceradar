defmodule ServiceRadarWebNG.Topology.AtlasRequestTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.AtlasRequest

  @moduletag :db_free

  test "canonicalizes level aliases before assigning a cache identity" do
    assert {:ok, ["global", "global:2:1"]} =
             AtlasRequest.parse_levels(%{"level_ids" => ["global:0:0", "global", "global:02:01"]})
  end

  test "watch limits apply before deduplication and every identifier must be valid" do
    assert {:ok, ["global"]} = AtlasRequest.parse_levels(%{})
    assert {:ok, []} = AtlasRequest.parse_levels(%{"level_ids" => []})
    assert {:ok, ["global"]} = AtlasRequest.parse_levels(%{"level_ids" => List.duplicate("global", 64)})

    for ids <- [List.duplicate("global", 65), "global", ["global", ""], [nil], [%{}], [String.duplicate("a", 2_049)]] do
      assert {:error, :invalid_levels} = AtlasRequest.parse_levels(%{"level_ids" => ids})
    end
  end

  test "stale revisions identify current content and unexpected failures expose no backend detail" do
    assert {409, %{error: "stale_revision", current_revision: 23}} =
             AtlasRequest.error_response({:stale_revision, 23})

    assert {503, %{error: "atlas_unavailable"}} =
             AtlasRequest.error_response({:database, "invented internal failure detail"})

    assert {503, %{error: "source_changed"}} = AtlasRequest.error_response(:source_changed)
  end
end
