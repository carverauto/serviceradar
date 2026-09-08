defmodule ServiceRadar.Inventory.VisibilityProfileSrqlTargetResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadar.Inventory.VisibilityProfileSrqlTargetResolver

  @tag :visibility
  test "blank target_query defaults to in:devices" do
    assert VisibilityProfileSrqlTargetResolver.target_query_for_match(%VisibilityProfile{
             target_query: nil
           }) == "in:devices"

    assert VisibilityProfileSrqlTargetResolver.target_query_for_match(%VisibilityProfile{
             target_query: "   "
           }) == "in:devices"
  end

  @tag :visibility
  test "non-blank target_query is trimmed and preserved" do
    assert VisibilityProfileSrqlTargetResolver.target_query_for_match(%VisibilityProfile{
             target_query: "  in:devices tags.role:camera  "
           }) == "in:devices tags.role:camera"
  end
end
