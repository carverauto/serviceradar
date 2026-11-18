defmodule ServiceRadarWebNGWeb.SRQL.CatalogRumTest do
  @moduledoc """
  DB-free contract tests for `in:rum` / `in:rum_beacons` SRQL catalog
  and dual-dialect (CNPG + StarRocks) translation.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SRQL.Native
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog
  alias ServiceRadarWebNGWeb.SRQL.Page

  @moduletag :db_free

  test "catalog exposes rum entity with expected route, defaults, and aliases" do
    entity = Catalog.entity("rum")
    assert entity.id == "rum"
    assert entity.route == "/dashboards/web-rum"
    assert entity.default_sort_field == "observed_at"
    assert entity.default_sort_dir == "desc"
    assert "has_error" in entity.boolean_fields
    assert "lcp_ms" in entity.filter_fields
    assert "prefix_tag" in entity.filter_fields
    assert "cdn_pop" in entity.stats_fields
    assert "cdn_provider" in entity.stats_fields
    assert "asn" in entity.stats_fields
    assert "as_org" in entity.stats_fields
    assert "canonical_origin" in entity.stats_fields

    for alias_name <- ~w(rum rum_beacons rum_beacon) do
      assert Catalog.entity(alias_name).id == "rum"
      assert {:ok, _ast} = Native.parse_ast("in:#{alias_name} limit:1")
    end

    assert Builder.build(Builder.default_state("rum", 50)) ==
             "in:rum time:last_24h sort:observed_at:desc limit:50"
  end

  test "page routing resolves in:rum to /dashboards/web-rum" do
    assert Page.route_target_for_query("in:rum has_error:true", "/devices") ==
             {"/dashboards/web-rum", %{}}
  end

  test "Rust translator builds both CNPG and StarRocks queries for in:rum" do
    query =
      "in:rum web_property_id:01JWEBPROP0000000000000001 lcp_ms:>1500 has_error:true sort:observed_at:desc limit:10"

    assert {:ok, cnpg_json} = Native.translate(query, nil, nil, nil, nil)
    cnpg = Jason.decode!(cnpg_json)
    assert cnpg["sql"] =~ "platform.rum_beacons" or cnpg["sql"] =~ "\"rum_beacons\""
    assert cnpg["sql"] =~ "lcp_ms"

    assert {:ok, sr_json} = Native.translate(query, nil, nil, nil, "starrocks")
    sr = Jason.decode!(sr_json)
    assert sr["sql"] =~ "serviceradar.rum_beacons"
    assert sr["sql"] =~ "`has_error` = TRUE"

    stats_query =
      ~s{in:rum_beacons time:last_24h stats:"count() as beacons, avg(lcp_ms) as avg_lcp by metric_path" limit:10}

    assert {:ok, cnpg_stats_json} = Native.translate(stats_query, nil, nil, nil, nil)
    assert Jason.decode!(cnpg_stats_json)["sql"] =~ "jsonb_build_object"

    assert {:ok, sr_stats_json} = Native.translate(stats_query, nil, nil, nil, "starrocks")
    assert Jason.decode!(sr_stats_json)["sql"] =~ "AVG(`lcp_ms`)"
  end
end
