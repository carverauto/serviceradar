defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FiltersTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters

  test "upsert_query_filter adds multi-colon tag values" do
    q = Filters.upsert_query_filter("in:flows", "tag", "site:austin")
    assert q == "in:flows tag:site:austin"
  end

  test "upsert_query_filter replaces existing tag filter" do
    q = Filters.upsert_query_filter("in:flows tag:site:austin src_ip:10.0.0.1", "tag", "role:guest-wifi")

    assert q =~ "tag:role:guest-wifi"
    assert q =~ "src_ip:10.0.0.1"
    refute q =~ "tag:site:austin"
  end

  test "upsert_query_filter clears tag when value empty" do
    q = Filters.upsert_query_filter("in:flows tag:site:austin", "tag", "")

    assert q == "in:flows"
  end

  test "flows_filter_patch encodes tag into URL" do
    path =
      Filters.flows_filter_patch(
        "/observability/flows",
        "in:flows",
        100,
        nil,
        "tag",
        "netbox:tag:iot"
      )

    assert path =~ "q="
    assert path =~ "tag"
    assert path =~ "netbox"
  end
end
